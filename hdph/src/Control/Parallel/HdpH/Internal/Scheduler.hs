-- Work stealing scheduler and thread pools
--
-- Author: Patrick Maier
-----------------------------------------------------------------------------


{-# LANGUAGE GeneralizedNewtypeDeriving #-}  -- req'd for type 'RTS'
{-# LANGUAGE ScopedTypeVariables #-}         -- req'd for type annotations

module Control.Parallel.HdpH.Internal.Scheduler
  ( -- * abstract run-time system monad
    RTS,          -- instances: Monad, Functor
    run_,         -- :: RTSConf -> IO () -> IO ()
    forkStub,     -- :: IO () -> IO ThreadId

    -- * scheduler ID
    schedulerID,  -- :: IO Int

    -- * converting and executing threads
    mkThread,     -- :: ParM IO a -> Thread
    execThread,   -- :: Thread -> IO ()
    execHiThread, -- :: Thread -> IO ()

    -- * pushing sparks
    sendPUSH      -- :: Spark IO -> Node -> IO ()
  ) where

import Prelude hiding (error)
import Control.Applicative (Applicative)
import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Monad (unless, when, void)
import qualified Data.ByteString.Lazy as BS
import Data.Functor ((<$>))


import Control.Parallel.HdpH.Closure (unClosure)
import Control.Parallel.HdpH.Conf (RTSConf(scheds, wakeupDly))
import qualified Control.Parallel.HdpH.Internal.Comm as Comm
       (myNode, allNodes, isRoot, send, receive, withCommDo)
import qualified Control.Parallel.HdpH.Internal.Data.Deque as Deque (emptyIO)
import qualified Control.Parallel.HdpH.Internal.Data.Sem as Sem
       (new, signalPeriodically)
import Control.Parallel.HdpH.Internal.Location
       (Node, dbgStats, dbgMsgSend, dbgMsgRcvd, error)
import qualified Control.Parallel.HdpH.Internal.Location as Location (debug)
import Control.Parallel.HdpH.Internal.Misc
       (encodeLazy, decodeLazy, ActionServer, newServer, killServer)
import Control.Parallel.HdpH.Internal.Sparkpool
       (SparkM, blockSched, getLocalSpark, Msg(TERM,PUSH), dispatch,
        readFishSentCtr, readSparkRcvdCtr, readSparkGenCtr, getDistsIO)
import qualified Control.Parallel.HdpH.Internal.Sparkpool as Sparkpool (run)
import Control.Parallel.HdpH.Internal.Threadpool
       (ThreadM, poolID, forkThreadM, stealThread, readMaxThreadCtrs)
import qualified Control.Parallel.HdpH.Internal.Threadpool as Threadpool (run)
import Control.Parallel.HdpH.Internal.Type.Par
       (ParM, unPar, Thread(Atom), ThreadCont(ThreadCont, ThreadDone), Spark)
import Control.Parallel.HdpH.Internal.State.RTSState (RTSState, initialiseRTSState, rtsState)

-- Fork a new thread to execute the given 'RTS' action; the integer 'n'
-- dictates how much to rotate the thread pools (so as to avoid contention
-- due to concurrent access).
forkRTS :: Int -> IO () -> IO ThreadId
forkRTS = forkThreadM

-- Fork a stub to stand in for an external computing resource (eg. GAP).
-- Will share thread pool with message handler.
forkStub :: IO () -> IO ThreadId
forkStub = forkRTS 0


-- Eliminate the whole RTS monad stack down the IO monad by running the given
-- RTS action 'main'; aspects of the RTS's behaviour are controlled by
-- the respective parameters in the given RTSConf.
-- NOTE: This function start various threads (for executing schedulers, 
--       a message handler, and various timeouts). On normal termination,
--       all these threads are killed. However, there is no cleanup in the 
--       event of aborting execution due to an exception. The functions
--       for doing so (see Control.Execption) all live in the IO monad.
--       Maybe they could be lifted to the RTS monad by using the monad-peel
--       package.
run_ :: RTSConf -> IO () -> IO ()
run_ conf main = do
  let n = scheds conf
  unless (n > 0) $
    error "HdpH.Internal.Scheduler.run_: no schedulers"

  -- allocate n+1 empty thread pools (numbered from 0 to n)
  pools <- mapM (\ k -> do { pool <- Deque.emptyIO; return (k,pool) }) [0 .. n]

  -- fork nowork server (for clearing the "FISH outstanding" flag on NOWORK)
  noWorkServer <- newServer

  -- create semaphore for idle schedulers
  idleSem <- Sem.new

  -- fork wakeup server (periodically waking up racey sleeping scheds)
  wakeupServerTid <- forkIO $ Sem.signalPeriodically idleSem (wakeupDly conf)

  initialiseRTSState conf noWorkServer idleSem pools

  Comm.withCommDo conf $ rts n noWorkServer wakeupServerTid

  -- RTS action
  where rts :: Int -> ActionServer -> ThreadId -> IO ()
        rts n_scheds noWorkServer wakeupServerTid = do
          -- get some data from Comm module
          all_nodes@(me:_) <- Comm.allNodes
          is_root <- Comm.isRoot

          -- create termination barrier
          barrier <- newEmptyMVar

          -- fork message handler (accessing thread pool 0)
          let n_nodes = if is_root then length all_nodes else 0
          handlerTid <- forkRTS 0 (handler barrier n_nodes)

          -- fork schedulers (each accessing thread pool k, 1 <= k <= n_scheds)
          schedulerTids <- mapM (\ k -> forkRTS k scheduler) [1 .. n_scheds]

          -- run main RTS action
          main

          -- termination
          when is_root $ do
            -- root: send TERM msg to all nodes to lift termination barrier
            everywhere <-  Comm.allNodes
            let term_msg = encodeLazy (TERM me)
            mapM_ (\ node -> Comm.send node term_msg) everywhere

          -- all nodes: block waiting for termination barrier
          takeMVar barrier

          -- print stats
          printFinalStats

          -- kill nowork server
          killServer noWorkServer

          -- kill wakeup server
          killThread wakeupServerTid

          -- kill message handler
          killThread handlerTid

          -- kill schedulers
          mapM_ killThread schedulerTids

-- Return scheduler ID, that is ID of scheduler's own thread pool.
schedulerID :: IO Int
schedulerID = poolID

-----------------------------------------------------------------------------
-- cooperative scheduling

-- Converts 'Par' computations into threads (of whatever priority).
mkThread :: ParM a -> Thread
mkThread p = unPar p $ \ _c -> Atom (\ _ -> return $ ThreadDone [])


-- Execute the given (low priority) thread until it blocks or terminates.
execThread :: Thread -> IO ()
execThread = runThread (return ())

-- Execute the given (high priority) thread until it and all its high
-- priority descendents block or terminate.
execHiThread :: Thread -> IO ()
execHiThread = runHiThreads (return ()) []


-- Try to get a thread from a thread pool or the spark pool and execute it
-- (with low priority) until it blocks or terminates, whence repeat forever;
-- if there is no thread to execute then block the scheduler (ie. its
-- underlying IO thread).
scheduler :: IO ()
scheduler = getThread >>= runThread scheduler


-- Try to steal a thread from any thread pool (with own pool preferred);
-- if there is none, try to convert a spark from the spark pool;
-- if there is none too, block the scheduler such that the 'getThread'
-- action will be repeated on wake up.
-- NOTE: Sleeping schedulers should be woken up
--       * after new threads have been added to a thread pool,
--       * after new sparks have been added to the spark pool, and
--       * once the delay after a NOWORK message has expired.
getThread :: Pools -> IO Thread
getThread = do
  schedID <- schedulerID
  maybe_thread <- stealThread
  case maybe_thread of
    Just thread -> return thread
    Nothing     -> do
      maybe_spark <- getLocalSpark schedID
      case maybe_spark of
        Just spark -> return $ mkThread $ unClosure spark
        Nothing    -> blockSched >> getThread


-- Execute given (low priority) thread until it blocks or terminates,
-- whence action 'onTerm' is executed.
-- NOTE: Any high priority threads arising during the execution of 'runThread'
--       are executed immediately by a call to 'runHiThreads'.
runThread :: IO () -> Thread -> IO ()
runThread onTerm (Atom m) = do
  x <- m False  -- action 'm' executed in low priority context
  case x of
    ThreadCont (ht:hts) t -> runHiThreads (runThread onTerm t) hts ht
    ThreadCont []       t -> runThread onTerm t
    ThreadDone (ht:hts)   -> runHiThreads onTerm hts ht
    ThreadDone []         -> onTerm

-- Execute given high priority thread and given stack of such threads
-- until they all block or terminate, whence action 'onTerm' is executed.
runHiThreads :: IO () -> [Thread] -> Thread -> IO ()
runHiThreads onTerm stack (Atom m) = do
  x <- m True   -- action 'm' executed in high priority context
  case x of
    ThreadCont hts ht -> runHiThreads onTerm (hts ++ stack) ht
    ThreadDone hts    -> case hts ++ stack of
                           ht:hts' -> runHiThreads onTerm hts' ht
                           []      -> onTerm


-----------------------------------------------------------------------------
-- pushed sparks

-- Send a 'spark' via PUSH message to the given 'target' unless 'target'
-- is the current node (in which case 'spark' is executed immediately
-- as a high priority thread).
sendPUSH :: Spark -> Node -> IO ()
sendPUSH spark target = do
  here <- Comm.myNode
  if target == here
    then do
      -- short cut PUSH msg locally
      execHiThread $ mkThread $ unClosure spark
    else do
      -- construct and send PUSH message
      let msg = PUSH spark :: Msg
      debug dbgMsgSend $ let msg_size = BS.length (encodeLazy msg) in
        show msg ++ " ->> " ++ show target ++ " Length: " ++ (show msg_size)
      Comm.send target $ encodeLazy msg


-- Handle a PUSH message by converting the spark into a high priority thread
-- and executing it immediately.
handlePUSH :: Msg -> IO ()
handlePUSH (PUSH spark) = execHiThread $ mkThread $ unClosure spark
handlePUSH _ = error "panic in handlePUSH: not a PUSH message"


-- Handle a TERM message, depending on whether this node is root or not.
handleTERM :: MVar () -> Int -> Msg -> IO Int
handleTERM term_barrier term_count msg@(TERM root) = do
  if term_count == 0
    then do -- non-root node: deflect TERM msg, lift term barrier, term handler
            Comm.send root $ encodeLazy msg
            void $ tryPutMVar term_barrier ()
            return (-1)
    else -- root node
         if term_count > 1
           then do -- at least one TERM msg outstanding: decrement term count
                   return $! (term_count - 1)
           else do -- last TERM msg received: lift term barrier, term handler
                   void $ tryPutMVar term_barrier ()
                   return (-1)
handleTERM _ _ _ = error "panic in handleTERM: not a TERM message"


-----------------------------------------------------------------------------
-- message handler; only PUSH and TERM messages are actually handled here in
-- this module, other messages are relegated to module Sparkpool.

-- Message handler, running continously (in its own thread) receiving
-- and handling messages (some of which may unblock threads or create sparks)
-- as they arrive. Message handler terminates on receiving TERM message(s).
handler :: MVar () -> Int -> IO ()
handler term_barrier term_count =
  when (term_count >= 0) $ do
    msg <- decodeLazy <$> Comm.receive
    debug dbgMsgRcvd $
      ">> " ++ show msg
    case msg of
      TERM _ -> handleTERM term_barrier term_count msg >>= handler term_barrier
      PUSH _ -> handlePUSH msg >> handler term_barrier term_count
      _      -> dispatch msg   >> handler term_barrier term_count


-----------------------------------------------------------------------------
-- auxiliary stuff

-- Print stats (#sparks, threads, FISH, ...) at appropriate debug level.
-- TODO: Log time elapsed since IO is up
printFinalStats :: IO ()
printFinalStats = do
  -- TODO: Get this stats data from the state
  fishes       <- readFishSentCtr
  schedules    <- readSparkRcvdCtr
  sparks       <- readSparkGenCtr
  -- max_sparks   <- liftSparkM $ readMaxSparkCtrs
  maxs_threads <- readMaxThreadCtrs
  debug dbgStats $ "#SPARK=" ++ show sparks ++ "   " ++
                   --"max_SPARK=" ++ show max_sparks ++ "   " ++
                   "max_THREAD=" ++ show maxs_threads
  debug dbgStats $ "#FISH_sent=" ++ show fishes ++ "   " ++
                   "#SCHED_rcvd=" ++ show schedules

debug :: Int -> String -> IO ()
debug level message = Location.debug level message
