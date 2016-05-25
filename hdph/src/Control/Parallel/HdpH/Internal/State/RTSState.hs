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
  ) where

import Control.Parallel.HdpH.Conf (RTSConf)

import Control.Parallel.HdpH.Internal.Data.Sem (Sem)
import Control.Parallel.HdpH.Internal.Data.Deque (DequeIO)
import Control.Parallel.HdpH.Internal.Data.DistMap (DistMap)
import qualified Control.Parallel.HdpH.Internal.Data.DistMap as DistMap (new)

import Control.Parallel.HdpH.Internal.Type.Par (Thread, Spark)
import Control.Parallel.HdpH.Internal.Misc (ActionServer)
import Control.Parallel.HdpH.Internal.Location (Node)
import Control.Parallel.HdpH.Internal.Sparkpool (getDistsIO)
import Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue (WorkQueueIO)
import qualified Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue as WorkQueue (emptyIO)

import Data.IORef (IORef, newIORef, writeIORef)

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
