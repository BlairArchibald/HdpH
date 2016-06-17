-- Thread pool and work stealing
--
-- Author: Patrick Maier
-----------------------------------------------------------------------------

module Control.Parallel.HdpH.Internal.Threadpool
  ( -- * thread pool monad
    forkThreadM,  -- :: Int -> IO () -> IO Control.Concurrent.ThreadId

    -- * thread pool ID (of scheduler's own pool)
    poolID,       -- :: IO Int

    -- * putting threads into the scheduler's own pool
    putThread,    -- :: Thread -> IO ()
    putThreads,   -- :: [Thread] -> IO ()

    -- * stealing threads (from scheduler's own pool, or from other pools)
    stealThread,  -- :: IO (Maybe (Thread))

    -- * statistics
    readMaxThreadCtrs  -- :: IO [Int]
  ) where

import Prelude hiding (error)
import Control.Concurrent (ThreadId)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.Trans (lift)

import Data.IORef (readIORef)

import Control.Parallel.HdpH.Internal.Data.Deque
       (DequeIO, pushFrontIO, popFrontIO, popBackIO, maxLengthIO)
import Control.Parallel.HdpH.Internal.Location (error)
import Control.Parallel.HdpH.Internal.Misc (fork, rotate)
import Control.Parallel.HdpH.Internal.Sparkpool (wakeupSched)
import Control.Parallel.HdpH.Internal.Type.Par (Thread)

import Control.Parallel.HdpH.Internal.State.RTSState

-- Execute the given 'ThreadM' action in a new thread, sharing the same
-- thread pools (but rotated by 'n' pools).

type Pools = [(Int, DequeIO Thread)]

-- What does this do now, used to call run to run a reader with the pools rotated
-- Threadpools are since we have one pool per scheduler, a thread has a view on a pool but they all point to one thing. Perhaps we should be using a map for this?
forkThreadM :: Pools -> Int -> (Pools -> IO ()) -> IO ThreadId
forkThreadM pools n action = do
  fork $ action (rotate n pools)

-----------------------------------------------------------------------------
-- access to thread pool

-- Return thread pool ID, that is ID of scheduler's own pool.
poolID :: Pools -> IO Int
poolID (myPool:_) = return $ fst myPool

-- Read the max size of each thread pool.
readMaxThreadCtrs :: IO [Int]
readMaxThreadCtrs = readIORef rtsState >>= mapM (maxLengthIO . snd) . sTpools

-- Steal a thread from any thread pool, with own pool as highest priority;
-- threads from own pool are always taken from the front; threads from other
-- pools are stolen from the back of those pools.
-- Rationale: Preserve locality as much as possible for own threads; try
-- not to disturb locality for threads stolen from others.
stealThread :: Pools -> IO (Maybe Thread)
stealThread (my_pool:other_pools) = do
  maybe_thread <- popFrontIO $ snd my_pool
  case maybe_thread of
    Just _  -> return maybe_thread
    Nothing -> steal other_pools
      where
        steal :: [(Int, DequeIO Thread)] -> IO (Maybe Thread)
        steal []           = return Nothing
        steal (pool:pools) = do
          maybe_thread' <- popBackIO $ snd pool
          case maybe_thread' of
            Just _  -> return maybe_thread'
            Nothing -> steal pools


-- Put the given thread at the front of the executing scheduler's own pool;
-- wake up 1 sleeping scheduler (if there is any).
putThread :: Pools -> Thread -> IO ()
putThread (my_pool:_) thread = do
  pushFrontIO (snd my_pool) thread
  wakeupSched 1

-- Put the given threads at the front of the executing scheduler's own pool;
-- the last thread in the list will end up at the front of the pool;
-- wake up as many sleeping schedulers as threads added.
putThreads :: Pools -> [Thread] -> IO ()
putThreads all_pools@(my_pool:_) threads = do
  mapM_ (pushFrontIO $ snd my_pool) threads
  wakeupSched (min (length all_pools) (length threads))
