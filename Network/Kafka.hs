{-# LANGUAGE OverloadedStrings #-}
module Network.Kafka where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network
import System.IO
import Data.Serialize.Get
import Control.Monad (liftM, forever, replicateM)
import Control.Concurrent.Chan
import Control.Concurrent (forkIO)
import Control.Exception (bracket)
import Data.List (find, groupBy, sortBy, transpose)
import Data.Maybe (mapMaybe)

import Network.Kafka.Protocol

withConnection :: (Handle -> IO c) -> IO c
withConnection = withConnection' ("localhost", 9092)

withConnection' :: (HostName, PortNumber) -> (Handle -> IO c) -> IO c
withConnection' (host, port) = bracket (connectTo host $ PortNumber port) hClose

produceLots :: ByteString -> [ByteString] -> Handle -> IO [Either String Response]
produceLots t ms h = mapM go ms
  where
    go m = do
      let r = client $ produceRequest 0 t Nothing m
      -- threadDelay 200000
      req r h

produceLots' t ms h = mapM_ go ms
  where
    go m = do
      let r = client $ produceRequest 0 t Nothing m
      -- threadDelay 200000
      req r h

producer seed topic ms = do
  resp <- withConnection' seed $ req $ client $ metadataRequest [topic]
  leader <- case resp of
    Left s -> error s
    Right (Response (_, (MetadataResponse mr))) -> case leaderFor topic mr of
      Nothing -> error "uh, there should probably be a leader..."
      Just leader -> return leader
    _ -> error "omg!"
  -- let r = client . produceRequest 0 topic Nothing
      -- go m = threadDelay 200000 >> req . (r m)
  withConnection' leader $ req $ client $ produceRequests 0 topic ms

producer' seed topic ms = do
  resp <- withConnection' seed $ req $ client $ metadataRequest [topic]
  leader <- case resp of
    Left s -> error s
    Right (Response (_, (MetadataResponse mr))) -> case leaderFor topic mr of
      Nothing -> error "uh, there should probably be a leader..."
      Just leader -> return leader
    _ -> error "omg!"
  -- let r = client . produceRequest 0 topic Nothing
      -- go m = threadDelay 200000 >> req . (r m)
  withConnection' leader $ produceLots topic ms

producer'' seed topic ms = do
  resp <- withConnection' seed $ req $ client $ metadataRequest [topic]
  leader <- case resp of
    Left s -> error s
    Right (Response (_, (MetadataResponse mr))) -> case leaderFor topic mr of
      Nothing -> error "uh, there should probably be a leader..."
      Just leader -> return leader
    _ -> error "omg!"
  -- let r = client . produceRequest 0 topic Nothing
      -- go m = threadDelay 200000 >> req . (r m)
  withConnection' leader $ produceLots' topic ms

produceStuff :: (HostName, PortNumber) -> ByteString -> [ByteString] -> IO [Either String Response]
produceStuff seed topic ms = do
  resp <- withConnection' seed $ req $ client $ metadataRequest [topic]
  leaders <- case resp of
    Left s -> error s
    Right (Response (_, (MetadataResponse mr))) -> return $ leadersFor topic mr
  chans <- replicateM (length leaders) newChan
  outChan <- newChan
  let actions = map (\(p, leader) -> (p, withConnection' leader)) leaders
      actions' = zip chans actions
  mapM_ (\ (chan, (p, (host, port))) -> forkIO $ do
    h <- connectTo host $ PortNumber port
    forever (readChan chan >>= ((flip req) h . client . produceRequests p topic) >>= writeChan outChan)) (zip chans leaders)

  let mss = map (\xs -> map snd xs) $ groupBy (\ (x,_) (y,_) -> x == y) $ sortBy (\ (x,_) (y,_) -> x `compare` y) $ zip (cycle [1..5]) ms

  mapM_ (\ (chan, ms) -> writeChan chan ms) (zip (cycle chans) mss)
  replicateM (length mss) (readChan outChan)

-- |As long as the supplied "Maybe" expression returns "Just _", the loop
-- body will be called and passed the value contained in the 'Just'.  Results
-- are discarded.
whileJust_ :: (Monad m) => m (Maybe a) -> (a -> m b) -> m ()
whileJust_ p f = go
    where go = do
            x <- p
            case x of
                Nothing -> return ()
                Just x  -> do
                        f x
                        go

chanReq :: Chan (Maybe a) -> Chan b -> (a -> IO b) -> IO ()
chanReq cIn cOut f = do whileJust_ (readChan cIn) $ \msg -> f msg >>= writeChan cOut

transformChan :: (a -> IO b) -> Chan (Maybe a) -> IO (Chan b)
transformChan f cIn = do
  cOut <- newChan
  forkIO $ whileJust_ (readChan cIn) $ \msg -> f msg >>= writeChan cOut
  return cOut

-- leadersFor :: ByteString -> MetadataResponse -> [(Partition, (String, PortNumber))]
leadersFor :: Num a => ByteString -> MetadataResponse -> [(a, (String, PortNumber))]
leadersFor topicName (MetadataResp (bs, ts)) =
  let bs' = map (\(Broker (NodeId x, (Host (KString h)), (Port p))) -> (x, (B.unpack h, fromIntegral p))) bs
      isTopic (TopicMetadata (e, TName (KString tname),_)) =
        tname == topicName && e == NoError
  in case find isTopic ts of
    (Just (TopicMetadata (_, _, ps))) ->
      mapMaybe (\(PartitionMetadata (pErr, Partition pid, Leader (Just leaderId), _, _)) ->
        (if pErr == NoError then lookup leaderId bs' else Nothing) >>= \x -> return (fromIntegral pid, x)) ps
    Nothing -> []

leaderFor :: ByteString -> MetadataResponse -> Maybe (String, PortNumber)
leaderFor topicName (MetadataResp (bs, ts)) = do
  let bs' = map (\(Broker (NodeId x, (Host (KString h)), (Port p))) -> (x, (B.unpack h, fromIntegral p))) bs
      isTopic (TopicMetadata (_, TName (KString tname),_)) = tname == topicName
      isPartition (PartitionMetadata (_, Partition x, _, _, _)) = x == 0
  (TopicMetadata (tErr, _, ps)) <- find isTopic ts
  if tErr /= NoError then Nothing else Just tErr
  (PartitionMetadata (pErr, _, Leader (Just leaderId), _, _)) <- find isPartition ps
  if pErr /= NoError then Nothing else Just tErr
  lookup leaderId bs'

-- Response (CorrelationId 0,MetadataResponse (MetadataResp (
-- [Broker (NodeId 1,Host (KString "192.168.33.1"),Port 9093),Broker (NodeId 0,Host (KString "192.168.33.1"),Port 9092),Broker (NodeId 2,Host (KString "192.168.33.1"),Port 9094)],
-- [TopicMetadata (
--   ErrorCode 0,
--   TName (KString "replicated"),
--   [PartitionMetadata (
--     ErrorCode 0,
--     Partition 0,
--     Leader (Just 1),
--     Replicas [1,0,2],
--     Isr [1,0])])])))

-- Response (CorrelationId 0,ProduceResponse (ProduceResp [(TName (KString "replicated"),[(Partition 0,ErrorCode 6,Offset (-1))])]))

req :: Request -> Handle -> IO (Either String Response)
req r h = do
  let bytes = requestBytes r
  B.hPut h bytes
  hFlush h
  let reader = B.hGet h
  rawLength <- reader 4
  let (Right dataLength) = runGet (liftM fromIntegral getWord32be) rawLength
  resp <- reader dataLength
  return $ runGet (getResponse dataLength) resp

reqbs :: Request -> Handle -> IO ByteString
reqbs r h = do
  let bytes = requestBytes r
  B.hPut h bytes
  hFlush h
  let reader = B.hGet h
  rawLength <- reader 4
  let (Right dataLength) = runGet (liftM fromIntegral getWord32be) rawLength
  resp <- reader dataLength
  return resp
