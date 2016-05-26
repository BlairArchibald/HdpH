-- Globally accessible RTS State
--
-- Author: Blair Archibald
-----------------------------------------------------------------------------

{-# LANGUAGE RecordWildCards #-}

module Control.Parallel.HdpH.Internal.State.RTSState
  (
    RTSState(..)
  , rtsState
  , initialiseRTSState

    -- State access
  , getRTSState
  , getPool
  , readPoolSize
  , getSparkOrigHist
  , readSparkOrigHist
  , setSparkOrigHist
  , clearSparkOrigHist
  , getFishingFlag
  , getNoWorkServer
  , getIdleSchedsSem
  , getFishSentCtr
  , readFishSentCtr
  , getSparkRcvdCtr
  , readSparkRcvdCtr
  , getSparkGenCtr
  , readSparkGenCtr
  , getSparkConvCtr
  , readSparkConvCtr
  , getMaxHops
  , getMaxFish
  , getMinSched
  , getMinFishDly
  , getMaxFishDly

  , readFlag
  , readCtr
  , setFlag
  , clearFlag
  , incCtr

  , singleNode
  , getEquiDistBasesIO
  , getDistsIO
  , getMinDistIO
  ) where

import Control.Parallel.HdpH.Conf (RTSConf(..))
import Control.Parallel.HdpH.Dist (Dist, zero, one, mul2, div2)

import Control.Parallel.HdpH.Internal.Data.Sem (Sem)
import Control.Parallel.HdpH.Internal.Data.Deque (DequeIO)
import Control.Parallel.HdpH.Internal.Data.DistMap (DistMap)
import qualified Control.Parallel.HdpH.Internal.Data.DistMap as DistMap (new, keys, minDist, lookup)
import qualified Control.Parallel.HdpH.Internal.Comm as Comm (equiDistBases, nodes)
import Control.Parallel.HdpH.Internal.Type.Par (Thread, Spark)
import Control.Parallel.HdpH.Internal.Misc (ActionServer)
import Control.Parallel.HdpH.Internal.Location (Node)
import Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue (WorkQueueIO, sizeIO)
import qualified Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue as WorkQueue (emptyIO)

import Data.IORef (IORef, newIORef, writeIORef, readIORef, atomicModifyIORef')

import System.IO.Unsafe (unsafePerformIO)

data RTSState =
  RTSState {
      sConf       :: RTSConf                 -- config data
    , sPools      :: DistMap (WorkQueueIO Spark) -- actual spark pools
    , sSparkOrig  :: IORef (Maybe Node)      -- primary FISH target (recent src)
    , sFishing    :: IORef Bool              -- True iff FISH outstanding
    , sNoWork     :: ActionServer            -- for clearing "FISH outstndg" flag
    , sIdleScheds :: Sem                     -- semaphore for idle schedulers
    , sFishSent   :: IORef Int               -- #FISH sent
    , sSparkRcvd  :: IORef Int               -- #sparks received
    , sSparkGen   :: IORef Int               -- #sparks generated
    , sSparkConv  :: IORef Int               -- #sparks converted
    , sTpools     :: [(Int, DequeIO Thread)] -- list of actual thread pools,
  }

-- Warning: Initially uninitialised
rtsState :: IORef RTSState
{-# NOINLINE rtsState #-}
rtsState = unsafePerformIO $ newIORef RTSState{..}

initialiseRTSState :: RTSConf
                   -> ActionServer
                   -> Sem
                   -> [(Int, DequeIO Thread)]
                   -> IO ()
initialiseRTSState conf noW idleS tps = do
  rs         <- getDistsIO
  sparkPools <- DistMap.new <$> sequence [WorkQueue.emptyIO | _ <- rs]
  sparkOrig  <- newIORef Nothing
  fishing    <- newIORef False
  -- TODO: Separate debugging state? Could hide via CPP for performance
  fishSent   <- newIORef 0
  sparkRcvd  <- newIORef 0
  sparkGen   <- newIORef 0
  sparkConv  <- newIORef 0

  let state = RTSState {
      sConf       = conf
    , sPools      = sparkPools
    , sSparkOrig  = sparkOrig
    , sFishing    = fishing
    , sNoWork     = noW
    , sIdleScheds = idleS
    , sFishSent   = fishSent
    , sSparkRcvd  = sparkRcvd
    , sSparkGen   = sparkGen
    , sSparkConv  = sparkConv
    , sTpools     = tps
  }

  writeIORef rtsState state

--------------------------------------------------------------------------------
-- State Manipulation
--------------------------------------------------------------------------------

-- TODO: Can lenses get rid of some of this?
getRTSState :: IO RTSState
getRTSState = readIORef rtsState

getPool :: Dist -> IO (WorkQueueIO Spark)
getPool r = DistMap.lookup r . sPools <$> getRTSState

readPoolSize :: Dist -> IO Int
readPoolSize r = getPool r >>= sizeIO

getSparkOrigHist :: IO (IORef (Maybe Node))
getSparkOrigHist = sSparkOrig <$> getRTSState

readSparkOrigHist :: IO (Maybe Node)
readSparkOrigHist = do
  useLastSteal <- useLastStealOptimisation . sConf <$> getRTSState
  if useLastSteal
   then getSparkOrigHist >>= readIORef
   else return Nothing

setSparkOrigHist :: Node -> IO ()
setSparkOrigHist mostRecentOrigin = do
  sparkOrigHistRef <- getSparkOrigHist
  writeIORef sparkOrigHistRef (Just mostRecentOrigin)

clearSparkOrigHist :: IO ()
clearSparkOrigHist = do
  sparkOrigHistRef <- getSparkOrigHist
  writeIORef sparkOrigHistRef Nothing

getFishingFlag :: IO (IORef Bool)
getFishingFlag = sFishing <$> getRTSState

getNoWorkServer :: IO ActionServer
getNoWorkServer = sNoWork <$> getRTSState

getIdleSchedsSem :: IO Sem
getIdleSchedsSem = sIdleScheds <$> getRTSState

getFishSentCtr :: IO (IORef Int)
getFishSentCtr = sFishSent <$> getRTSState

readFishSentCtr :: IO Int
readFishSentCtr = getFishSentCtr >>= readCtr

getSparkRcvdCtr :: IO (IORef Int)
getSparkRcvdCtr = sSparkRcvd <$> getRTSState

readSparkRcvdCtr :: IO Int
readSparkRcvdCtr = getSparkRcvdCtr >>= readCtr

getSparkGenCtr :: IO (IORef Int)
getSparkGenCtr = sSparkGen <$> getRTSState

readSparkGenCtr :: IO Int
readSparkGenCtr = getSparkGenCtr >>= readCtr

getSparkConvCtr :: IO (IORef Int)
getSparkConvCtr = sSparkConv <$> getRTSState

readSparkConvCtr :: IO Int
readSparkConvCtr = getSparkConvCtr >>= readCtr

-- Currently Unsupported by the priority queue

-- readMaxSparkCtr :: Dist -> IO m Int
-- readMaxSparkCtr r = getPool r >>= liftIO . maxLengthIO

-- readMaxSparkCtrs :: IO m [Int]
-- readMaxSparkCtrs = liftIO getDistsIO >>= mapM readMaxSparkCtr

getMaxHops :: IO Int
getMaxHops = maxHops . sConf <$> getRTSState

getMaxFish :: IO Int
getMaxFish = maxFish . sConf <$> getRTSState

getMinSched :: IO Int
getMinSched = minSched . sConf <$> getRTSState

getMinFishDly :: IO Int
getMinFishDly = minFishDly . sConf <$> getRTSState

getMaxFishDly :: IO Int
getMaxFishDly = maxFishDly . sConf <$> getRTSState

--------------------------------------------------------------------------------
-- Misc State functions
--------------------------------------------------------------------------------
readFlag :: IORef Bool -> IO Bool
readFlag = readIORef

readCtr :: IORef Int -> IO Int
readCtr = readIORef

-- Sets given 'flag'; returns True iff 'flag' did actually change.
setFlag :: IORef Bool -> IO Bool
setFlag flag = atomicModifyIORef' flag $ \ v -> (True, not v)

-- Clears given 'flag'; returns True iff 'flag' did actually change.
clearFlag :: IORef Bool -> IO Bool
clearFlag flag = atomicModifyIORef' flag $ \ v -> (False, v)

incCtr :: IORef Int -> IO ()
incCtr ctr = atomicModifyIORef' ctr $
              \ v -> let v' = v + 1 in v' `seq` (v', ())

-----------------------------------------------------------------------------
-- access to Comm module state
-- FIXME: Not sure about belonging to this module
--------------------------------------------------------------------------------

singleNode :: IO Bool
singleNode = (< 2) <$> Comm.nodes

getEquiDistBasesIO :: IO (DistMap [(Node, Int)])
getEquiDistBasesIO = Comm.equiDistBases

getDistsIO :: IO [Dist]
getDistsIO = DistMap.keys <$> Comm.equiDistBases

getMinDistIO :: IO Dist
getMinDistIO = DistMap.minDist <$> Comm.equiDistBases
