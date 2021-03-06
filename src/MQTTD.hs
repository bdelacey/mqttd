{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE UndecidableInstances       #-}

module MQTTD where

import           Control.Concurrent     (ThreadId, threadDelay, throwTo)
import           Control.Concurrent.STM (STM, TBQueue, TVar, isFullTBQueue, modifyTVar', newTBQueue, newTBQueueIO,
                                         newTVar, newTVarIO, readTVar, tryReadTBQueue, writeTBQueue, writeTVar)
import           Control.Lens
import           Control.Monad          (forever, unless, void, when)
import           Control.Monad.Catch    (MonadCatch (..), MonadMask (..), MonadThrow (..))
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Logger   (MonadLogger (..), logDebugN, logInfoN)
import           Control.Monad.Reader   (MonadReader (..), ReaderT (..), asks, local)
import           Data.Bifunctor         (first, second)
import           Data.Either            (rights)
import           Data.Foldable          (fold, foldl')
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (fromMaybe, isJust)
import           Data.Monoid            (Sum (..))
import           Data.Time.Clock        (addUTCTime, getCurrentTime)
import           Data.Word              (Word16)
import           Database.SQLite.Simple (Connection)
import           Network.MQTT.Lens
import qualified Network.MQTT.Topic     as T
import qualified Network.MQTT.Types     as T
import           UnliftIO               (MonadUnliftIO (..), atomically, readTVarIO)

import           MQTTD.Config           (ACL (..), User (..))
import           MQTTD.DB
import           MQTTD.GCStats
import           MQTTD.Retention
import           MQTTD.Stats
import           MQTTD.SubTree          (SubTree)
import qualified MQTTD.SubTree          as SubTree
import           MQTTD.Types
import           MQTTD.Util

import qualified Scheduler

data Env = Env {
  sessions     :: TVar (Map SessionID Session),
  lastPktID    :: TVar Word16,
  clientIDGen  :: TVar ClientID,
  allSubs      :: TVar (SubTree (Map SessionID T.SubOptions)),
  queueRunner  :: Scheduler.QueueRunner SessionID,
  retainer     :: Retainer,
  authorizer   :: Authorizer,
  dbConnection :: Connection,
  dbQ          :: TBQueue DBOperation,
  statStore    :: StatStore
  }

newtype MQTTD m a = MQTTD
  { runMQTTD :: ReaderT Env m a
  } deriving (Applicative, Functor, Monad, MonadIO, MonadLogger,
              MonadCatch, MonadThrow, MonadMask, MonadReader Env, MonadFail)

instance MonadUnliftIO m => MonadUnliftIO (MQTTD m) where
  withRunInIO inner = MQTTD $ withRunInIO $ \run -> inner (run . runMQTTD)

instance (Monad m, MonadReader Env m) => HasDBConnection m where
  dbConn = asks dbConnection
  dbQueue = asks dbQ

runIO :: (MonadIO m, MonadLogger m) => Env -> MQTTD m a -> m a
runIO e m = runReaderT (runMQTTD m) e

newEnv :: MonadIO m => Authorizer -> Connection -> m Env
newEnv a d = liftIO $ Env
         <$> newTVarIO mempty
         <*> newTVarIO 1
         <*> newTVarIO 0
         <*> newTVarIO mempty
         <*> Scheduler.newRunner
         <*> newRetainer
         <*> pure a
         <*> pure d
         <*> newTBQueueIO 100
         <*> newStatStore

modifyAuthorizer :: Monad m => (Authorizer -> Authorizer) -> MQTTD m a -> MQTTD m a
modifyAuthorizer f = local (\e@Env{..} -> e{authorizer=f authorizer})

seconds :: Num p => p -> p
seconds = (1000000 *)

nextID :: MonadIO m => MQTTD m Int
nextID = asks clientIDGen >>= \ig -> atomically $ modifyTVarRet ig (+1)

sessionCleanup :: PublishConstraint m => MQTTD m ()
sessionCleanup = asks queueRunner >>= Scheduler.run expireSession

retainerCleanup :: (MonadUnliftIO m, MonadLogger m) => MQTTD m ()
retainerCleanup = asks retainer >>= cleanRetainer

applyStats :: (MonadUnliftIO m, MonadLogger m) => MQTTD m ()
applyStats = asks statStore >>= MQTTD.Stats.applyStats

isClientConnected :: SessionID -> TVar (Map SessionID Session) ->  STM Bool
isClientConnected sid sidsv = readTVar sidsv >>= \sids -> pure $ isJust (_sessionClient =<< Map.lookup sid sids)

publishStats :: PublishConstraint m => MQTTD m ()
publishStats = forever (pubStats >> sleep 15)
  where
    sleep = liftIO . threadDelay . seconds

    pubStats = do
      pubClients
      pubSubs
      pubRetained
      pubCounters
      gce <- hasGCStats
      when gce $ pubGCStats pubBS

    pub k = pubBS k . textToBL . tshow

    pubBS k v = broadcast Nothing (T.PublishRequest {
                                      T._pubDup=False,
                                      T._pubQoS=T.QoS2,
                                      T._pubRetain=True,
                                      T._pubTopic=k,
                                      T._pubPktID=0,
                                      T._pubBody=v,
                                      T._pubProps=[T.PropMessageExpiryInterval 60]})

    pubClients = do
      ssv <- asks sessions
      ss <- readTVarIO ssv
      pub "$SYS/broker/clients/total" (length ss)
      pub "$SYS/broker/clients/connected" (length . filter (isJust . _sessionClient) . Map.elems $ ss)

    pubRetained = do
      r <- asks retainer
      m <- readTVarIO (_store r)
      pub "$SYS/broker/retained messages/count" (length m)

    pubSubs = do
      m <- readTVarIO =<< asks allSubs
      pub "$SYS/broker/subscriptions/count" (getSum $ foldMap (Sum . length) m)

    pubCounters = do
      m <- retrieveStats =<< asks statStore
      mapM_ (\(k, v) -> pub (statKeyName k) v) (Map.assocs m)

resolveAliasIn :: MonadIO m => Session -> T.PublishRequest -> m T.PublishRequest
resolveAliasIn Session{_sessionClient=Nothing} r = pure r
resolveAliasIn Session{_sessionClient=Just ConnectedClient{_clientAliasIn}} r =
  case r ^? properties . folded . _PropTopicAlias of
    Nothing -> pure r
    Just n  -> resolve n r

  where
    resolve n T.PublishRequest{_pubTopic} = do
      t <- atomically $ do
        when (_pubTopic /= "") $ modifyTVar' _clientAliasIn (Map.insert n _pubTopic)
        Map.findWithDefault "" n <$> readTVar _clientAliasIn
      pure $ r & pubTopic .~ t & properties %~ cleanProps
    cleanProps = filter (\case
                            (T.PropTopicAlias _) -> False
                            _ -> True)

findSubs :: MonadIO m => T.Topic -> MQTTD m [(Session, T.SubOptions)]
findSubs t = do
  subs <- asks allSubs
  sess <- asks sessions
  atomically $ do
    sm <- readTVar sess
    foldMap (\(sid,os) -> maybe [] (\s -> [(s,os)]) $ Map.lookup sid sm) . SubTree.findMap t Map.assocs <$> readTVar subs

restoreSessions :: PublishConstraint m => MQTTD m ()
restoreSessions = do
  ss <- loadSessions
  subs <- SubTree.fromList . fold <$> traverse flatSubs ss
  sessv <- asks sessions
  subv <- asks allSubs
  atomically $ do
    writeTVar sessv (Map.fromList . map (\s@Session{..} -> (_sessionID, s)) $ ss)
    writeTVar subv subs
  mapM_ (expireSession . _sessionID) ss

  where
    flatSubs :: MonadIO m => Session -> m [(T.Filter, Map SessionID T.SubOptions)]
    flatSubs Session{..} = Map.foldMapWithKey (\k v -> [(k, Map.singleton _sessionID v)]) <$> readTVarIO _sessionSubs

restoreRetained :: MonadIO m => MQTTD m ()
restoreRetained = asks retainer >>= MQTTD.Retention.restoreRetained

subscribe :: PublishConstraint m => Session -> T.SubscribeRequest -> MQTTD m ()
subscribe sess@Session{..} (T.SubscribeRequest pid topics props) = do
  subs <- asks allSubs
  let topics' = map (\(t,o) -> let t' = blToText t in
                                 bimap (const T.SubErrNotAuthorized) (const (t', o)) $ authTopic t' _sessionACL) topics
      new = Map.fromList $ rights topics'
  atomically $ do
    modifyTVar' _sessionSubs (Map.union new)
    modifyTVar' subs (upSub new)
    let r = map (second (T._subQoS . snd)) topics'
    sendPacket_ _sessionChan (T.SubACKPkt (T.SubscribeResponse pid r props))
  p <- asks retainer
  mapM_ (doRetained p) (Map.assocs new)
  storeSession sess

  where
    upSub m subs = Map.foldrWithKey (\k x -> SubTree.add k (Map.singleton _sessionID x)) subs m

    doRetained _ (_, T.SubOptions{T._retainHandling=T.DoNotSendOnSubscribe}) = pure ()
    doRetained p (t, ops) = mapM_ (sendOne ops) =<< matchRetained p t

    sendOne opts@T.SubOptions{..} ir@T.PublishRequest{..} = do
      pid' <- atomically . nextPktID =<< asks lastPktID
      let r = ir{T._pubPktID=pid', T._pubRetain=mightRetain opts,
                 T._pubQoS = if _pubQoS > _subQoS then _subQoS else _pubQoS}
      publish sess r

        where
          mightRetain T.SubOptions{_retainAsPublished=False} = False
          mightRetain _                                      = _pubRetain

removeSubs :: TVar (SubTree (Map SessionID T.SubOptions)) -> SessionID -> [T.Filter] -> STM ()
removeSubs subt sid ts = modifyTVar' subt up
  where
    up s = foldr (\t -> SubTree.modify t (Map.delete sid <$>)) s ts

unsubscribe :: MonadIO m => Session -> [BLFilter] -> MQTTD m [T.UnsubStatus]
unsubscribe Session{..} topics = asks allSubs >>= \subs ->
  atomically $ do
    m <- readTVar _sessionSubs
    let (uns, n) = foldl' (\(r,m') t -> first ((:r) . unm) $ up t m') ([], m) topics
    writeTVar _sessionSubs n
    removeSubs subs _sessionID (blToText <$> topics)
    pure (reverse uns)

    where
      unm = maybe T.UnsubNoSubscriptionExisted (const T.UnsubSuccess)
      up t = Map.updateLookupWithKey (const.const $ Nothing) (blToText t)

modifySession :: MonadIO m => SessionID -> (Session -> Maybe Session) -> MQTTD m ()
modifySession k f = asks sessions >>= \s -> atomically $ modifyTVar' s (Map.update f k)

registerClient :: (MonadFail m, MonadIO m)
               => T.ConnectRequest -> ClientID -> ThreadId -> MQTTD m (Session, T.SessionReuse)
registerClient req@T.ConnectRequest{..} i o = do
  c <- asks sessions
  ai <- liftIO $ newTVarIO mempty
  ao <- liftIO $ newTVarIO mempty
  l <- liftIO $ newTVarIO (fromMaybe 0 (req ^? properties . folded . _PropTopicAliasMaximum))
  authr <- asks (_authUsers . authorizer)
  let k = _connID
      nc = ConnectedClient req o i ai ao l
      acl = fromMaybe [] (fmap (\(User _ _ a) -> a) . (`Map.lookup` authr) =<< _username)
      maxInFlight = fromMaybe maxBound (req ^? properties . folded . _PropReceiveMaximum)
  when (maxInFlight == 0) $ fail "max in flight must be greater than zero"
  (o', x, ns) <- atomically $ do
    emptySession <- Session _connID acl (Just nc) <$> newTBQueue defaultQueueSize
                    <*> newTVar maxInFlight <*> newTBQueue defaultQueueSize
                    <*> newTVar mempty <*> newTVar mempty
                    <*> pure Nothing <*> pure _lastWill
    m <- readTVar c
    let s = Map.lookup k m
        o' = _sessionClient =<< s
        (ns, ruse) = maybeClean emptySession s
    writeTVar c (Map.insert k ns m)
    pure (o', ruse, ns)
  case o' of
    Nothing                  -> pure ()
    Just ConnectedClient{..} -> liftIO $ throwTo _clientThread (MQTTDuplicate _connID)
  pure (ns, x)

    where
      maybeClean ns Nothing = (ns, T.NewSession)
      maybeClean ns (Just s)
        | _cleanSession = (ns, T.NewSession)
        | otherwise = (s{_sessionClient=_sessionClient ns,
                         _sessionExpires=Nothing,
                         _sessionChan=_sessionChan ns,
                         _sessionBacklog=_sessionBacklog ns,
                         _sessionFlight=_sessionFlight ns,
                         _sessionWill=_lastWill}, T.ExistingSession)

expireSession :: PublishConstraint m => SessionID -> MQTTD m ()
expireSession k = do
  ss <- asks sessions
  possiblyCleanup =<< atomically (Map.lookup k <$> readTVar ss)

  where
    possiblyCleanup Nothing = pure ()
    possiblyCleanup (Just Session{_sessionClient=Just _}) = logDebugN (tshow k <> " is in use")
    possiblyCleanup (Just Session{_sessionClient=Nothing,
                                  _sessionExpires=Nothing}) = expireNow
    possiblyCleanup (Just Session{_sessionClient=Nothing,
                                  _sessionExpires=Just ex,
                                  _sessionSubs=subsv}) = do
      now <- liftIO getCurrentTime
      subs <- readTVarIO subsv
      if hasHighQoS subs && ex > now
        then Scheduler.enqueue ex k =<< asks queueRunner
        else expireNow

    hasHighQoS = isJust . preview (folded . subQoS . filtered (> T.QoS0))

    expireNow = do
      now <- liftIO getCurrentTime
      ss <- asks sessions
      kilt <- atomically $ do
        current <- Map.lookup k <$> readTVar ss
        subs <- maybe (pure mempty) readTVar (_sessionSubs <$> current)
        case current ^? _Just . sessionExpires . _Just of
          Nothing -> pure Nothing
          Just x -> if not (hasHighQoS subs) || now >= x
                    then
                      modifyTVar' ss (Map.delete k) >> pure current
                    else
                      pure Nothing
      case kilt of
        Nothing -> logDebugN ("Nothing expired for " <> tshow k)
        Just s@Session{..}  -> do
          logDebugN ("Expired session for " <> tshow k)
          subt <- asks allSubs
          atomically $ do
            subs <- readTVar _sessionSubs
            removeSubs subt _sessionID (Map.keys subs)
          deleteSession _sessionID
          sessionDied s

    sessionDied Session{_sessionWill=Nothing} =
      logDebugN ("Session without will: " <> tshow k <> " has died")
    sessionDied Session{_sessionWill=Just T.LastWill{..}} = do
      logDebugN ("Session with will " <> tshow k <> " has died")
      broadcast Nothing (T.PublishRequest{
                            T._pubDup=False,
                            T._pubQoS=_willQoS,
                            T._pubRetain=_willRetain,
                            T._pubTopic=_willTopic,
                            T._pubPktID=0,
                            T._pubBody=_willMsg,
                            T._pubProps=_willProps})

unregisterClient :: (MonadLogger m, MonadMask m, MonadFail m, MonadUnliftIO m, MonadIO m) => SessionID -> ClientID -> MQTTD m ()
unregisterClient k mid = do
  now <- liftIO getCurrentTime
  modifySession k (up now)
  expireSession k

    where
      up now sess@Session{_sessionClient=Just cc@ConnectedClient{_clientID=i}}
        | mid == i =
          case cc ^? clientConnReq . properties . folded . _PropSessionExpiryInterval of
            -- Default expiry
            Nothing -> Just $ sess{_sessionExpires=Just (addUTCTime defaultSessionExp now),
                                   _sessionClient=Nothing}
            -- Specifically destroy now
            Just 0 -> Just $ sess{_sessionExpires=Nothing, _sessionClient=Nothing}
            -- Hold on for maybe a bit.
            Just x  -> Just $ sess{_sessionExpires=Just (addUTCTime (fromIntegral x) now),
                                   _sessionClient=Nothing}
      up _ s = Just s

tryWriteQ :: TBQueue a -> a -> STM Bool
tryWriteQ q a = do
  full <- isFullTBQueue q
  unless full $ writeTBQueue q a
  pure full

sendPacket :: PktQueue -> T.MQTTPkt -> STM Bool
sendPacket = tryWriteQ

sendPacket_ :: PktQueue -> T.MQTTPkt -> STM ()
sendPacket_ q = void . sendPacket q

sendPacketIO :: MonadIO m => PktQueue -> T.MQTTPkt -> m Bool
sendPacketIO ch = atomically . sendPacket ch

sendPacketIO_ :: MonadIO m => PktQueue -> T.MQTTPkt -> m ()
sendPacketIO_ ch = void . atomically . sendPacket ch

modifyTVarRet :: TVar a -> (a -> a) -> STM a
modifyTVarRet v f = modifyTVar' v f >> readTVar v

nextPktID :: (Enum a, Bounded a, Eq a, Num a) => TVar a -> STM a
nextPktID x = modifyTVarRet x $ \pid -> if pid == maxBound then 1 else succ pid

broadcast :: PublishConstraint m => Maybe SessionID -> T.PublishRequest -> MQTTD m ()
broadcast src req@T.PublishRequest{..} = do
  asks retainer >>= retain req
  subs <- findSubs (blToText _pubTopic)
  pid <- atomically . nextPktID =<< asks lastPktID
  mapM_ (\(s@Session{..}, o) -> justM (publish s) (pkt _sessionID o pid)) subs
  where
    pkt sid T.SubOptions{T._noLocal=True} _
      | Just sid == src = Nothing
    pkt _ opts pid = Just req{
      T._pubDup=False,
      T._pubRetain=mightRetain opts,
      T._pubQoS=maxQoS opts,
      T._pubPktID=pid}

    maxQoS T.SubOptions{_subQoS} = if _pubQoS > _subQoS then _subQoS else _pubQoS
    mightRetain T.SubOptions{_retainAsPublished=False} = False
    mightRetain _                                      = _pubRetain

publish :: PublishConstraint m => Session -> T.PublishRequest -> MQTTD m ()
publish sess@Session{..} pkt@T.PublishRequest{..}
  -- QoS 0 is special-cased because it's fire-and-forget with no retries or anything.
  | _pubQoS == T.QoS0 = asks statStore >>= \ss -> atomically $ deliver ss sess pkt
  | otherwise = asks statStore >>= \ss -> atomically $ do
      modifyTVar' _sessionQP $ Map.insert (pkt ^. pktID) pkt
      tokens <- readTVar _sessionFlight
      if tokens == 0
        then void $ tryWriteQ _sessionBacklog pkt
        else deliver ss sess pkt

deliver :: StatStore -> Session -> T.PublishRequest -> STM ()
deliver ss Session{..} pkt@T.PublishRequest{..} = do
  when (_pubQoS > T.QoS0) $ modifyTVar' _sessionFlight pred
  p <- maybe (pure pkt) (`aliasOut` pkt) _sessionClient
  sendPacket_ _sessionChan (T.PublishPkt p)
  incrementStatSTM StatMsgSent 1 ss

aliasOut :: ConnectedClient -> T.PublishRequest -> STM T.PublishRequest
aliasOut ConnectedClient{..} pkt@T.PublishRequest{..} =
  maybe allocate existing . Map.lookup _pubTopic =<< readTVar _clientAliasOut
    where
      existing n = pure pkt{T._pubTopic="", T._pubProps=T.PropTopicAlias n:_pubProps}
      allocate = readTVar _clientALeft >>= \l ->
        if l == 0 then pure pkt
        else do
          modifyTVar' _clientALeft pred
          modifyTVar' _clientAliasOut (Map.insert _pubTopic l)
          pure pkt{T._pubProps=T.PropTopicAlias l:_pubProps}

authTopic :: T.Topic -> [ACL] -> Either String ()
authTopic "" = const $ Left "empty topics are not valid"
authTopic t = foldr check (Right ())
  where
    check (Allow f) o
      | T.match f t = Right ()
      | otherwise = o
    check (Deny f) o
      | T.match f t = Left "unauthorized topic"
      | otherwise = o

releasePubSlot :: StatStore -> Session -> STM ()
releasePubSlot ss sess@Session{..} = do
  modifyTVar' _sessionFlight succ
  justM (deliver ss sess) =<< tryReadTBQueue _sessionBacklog

dispatch :: PublishConstraint m => Session -> T.MQTTPkt -> MQTTD m ()

dispatch Session{..} T.PingPkt = sendPacketIO_ _sessionChan T.PongPkt

-- QoS 1 ACK (receiving client got our publish message)
dispatch sess@Session{..} (T.PubACKPkt ack) = asks statStore >>= \st -> atomically $ do
  modifyTVar' _sessionQP (Map.delete (ack ^. pktID))
  releasePubSlot st sess

-- QoS 2 ACK (receiving client received our message)
dispatch Session{..} (T.PubRECPkt ack) = atomically $ do
  modifyTVar' _sessionQP (Map.delete (ack ^. pktID))
  sendPacket_ _sessionChan (T.PubRELPkt $ T.PubREL (ack ^. pktID) 0 mempty)

-- QoS 2 REL (publishing client says we can ship the message)
dispatch Session{..} (T.PubRELPkt rel) = do
  pkt <- atomically $ do
    (r, m) <- Map.updateLookupWithKey (const.const $ Nothing) (rel ^. pktID) <$> readTVar _sessionQP
    writeTVar _sessionQP m
    _ <- sendPacket _sessionChan (T.PubCOMPPkt (T.PubCOMP (rel ^. pktID) (maybe 0x92 (const 0) r) mempty))
    pure r
  justM (broadcast (Just _sessionID)) pkt

-- QoS 2 COMPlete (publishing client says publish is complete)
dispatch sess (T.PubCOMPPkt _) = asks statStore >>= \st -> atomically $ releasePubSlot st sess

-- Subscribe response is sent from the `subscribe` action because the
-- interaction is a bit complicated.
dispatch sess@Session{..} (T.SubscribePkt req) = subscribe sess req

dispatch sess@Session{..} (T.UnsubscribePkt (T.UnsubscribeRequest pid subs props)) = do
  uns <- unsubscribe sess subs
  sendPacketIO_ _sessionChan (T.UnsubACKPkt (T.UnsubscribeResponse pid props uns))

dispatch sess@Session{..} (T.PublishPkt req) = do
  r@T.PublishRequest{..} <- resolveAliasIn sess req
  case authTopic (blToText _pubTopic) _sessionACL of
    Left _  -> logInfoN ("Unauthorized topic: " <> tshow _pubTopic) >> nak _pubQoS r
    Right _ -> satisfyQoS _pubQoS r

    where
      nak T.QoS0 _ = pure ()
      nak T.QoS1 T.PublishRequest{..} =
        sendPacketIO_ _sessionChan (T.PubACKPkt (T.PubACK _pubPktID 0x87 mempty))
      nak T.QoS2 T.PublishRequest{..} =
        sendPacketIO_ _sessionChan (T.PubRECPkt (T.PubREC _pubPktID 0x87 mempty))

      satisfyQoS T.QoS0 r = broadcast (Just _sessionID) r >> countIn
      satisfyQoS T.QoS1 r@T.PublishRequest{..} = do
        sendPacketIO_ _sessionChan (T.PubACKPkt (T.PubACK _pubPktID 0 mempty))
        broadcast (Just _sessionID) r
        countIn
      satisfyQoS T.QoS2 r@T.PublishRequest{..} = asks statStore >>= \ss -> atomically $ do
        sendPacket_ _sessionChan (T.PubRECPkt (T.PubREC _pubPktID 0 mempty))
        modifyTVar' _sessionQP (Map.insert _pubPktID r)
        incrementStatSTM StatMsgRcvd 1 ss

      countIn = incrementStat StatMsgRcvd 1 =<< asks statStore

dispatch sess (T.DisconnectPkt (T.DisconnectRequest T.DiscoNormalDisconnection _props)) = do
  let Just sid = sess ^? sessionClient . _Just . clientConnReq . connID
  modifySession sid (Just . set sessionWill Nothing)

dispatch _ (T.DisconnectPkt (T.DisconnectRequest T.DiscoDisconnectWithWill _props)) = pure ()

dispatch _ x = fail ("unhandled: " <> show x)
