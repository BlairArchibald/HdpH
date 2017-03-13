-- Spark pool and fishing
--
-- Author: Patrick Maier
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}  -- req'd for type annotations
{-# LANGUAGE BangPatterns #-}

module Control.Parallel.HdpH.Internal.Sparkpool
  (
    -- * blocking and unblocking idle schedulers
    blockSched,      -- :: IO ()
    wakeupSched,     -- :: Int -> IO ()

    -- * local (ie. scheduler) access to spark pool
    getLocalSpark,   -- :: Int -> IO (Maybe Spark)
    putLocalSpark,   -- :: Int -> Dist -> Spark -> IO ()
    -- :: Int -> Dist -> Priority -> Spark -> IO ()
    putLocalSparkWithPrio,

    -- * messages
    Msg(..),         -- instances: Show, NFData, Serialize

    -- * handle messages related to fishing
    dispatch,        -- :: Msg -> IO ()
    handleFISH,      -- :: Msg -> IO ()
    handleSCHEDULE,  -- :: Msg -> IO ()
    handleNOWORK,    -- :: Msg -> IO ()
  ) where

import Prelude hiding (error)
import Control.Concurrent (threadDelay)
import Control.DeepSeq (NFData, rnf)
import Control.Monad (when, replicateM_, void)
import Control.Monad.Trans.Reader (ReaderT, runReaderT, ask)
import Control.Monad.Trans.Class (lift)
import qualified Data.ByteString.Lazy as BS
import Data.Functor ((<$>))
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicModifyIORef)
import Data.List (insertBy, sortBy)
import Data.Ord (comparing)
import Data.Serialize (Serialize)
import qualified Data.Serialize (put, get)
import Data.Word (Word8)

import Data.IORef (readIORef)

import System.Random (randomRIO)

import Control.Parallel.HdpH.Conf
       (RTSConf( maxHops
               , maxFish
               , minSched
               , minFishDly
               , maxFishDly
               , useLastStealOptimisation
               , useLowWatermarkOptimisation))

import Control.Parallel.HdpH.Dist (Dist, zero, one, mul2, div2)
import qualified Control.Parallel.HdpH.Internal.Comm as Comm
       (send, nodes, myNode, equiDistBases)

import Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue
       (WorkQueueIO, Priority, enqueueTaskIO, dequeueTaskIO, emptyIO, sizeIO)

import Control.Parallel.HdpH.Internal.Data.DistMap (DistMap)
import qualified Control.Parallel.HdpH.Internal.Data.DistMap as DistMap
       (new, toDescList, lookup, keys, minDist)
import Control.Parallel.HdpH.Internal.Data.Sem (Sem)
import qualified Control.Parallel.HdpH.Internal.Data.Sem as Sem (wait, signal)
import Control.Parallel.HdpH.Internal.Location
       (Node, dbgMsgSend, dbgSpark, error)
import qualified Control.Parallel.HdpH.Internal.Location as Location (debug)
import Control.Parallel.HdpH.Internal.Topology (dist)
import Control.Parallel.HdpH.Internal.Misc (encodeLazy, ActionServer, reqAction)
import Control.Parallel.HdpH.Internal.Type.Par (Spark)
import Control.Parallel.HdpH.Internal.State.RTSState

-----------------------------------------------------------------------------
-- blocking and unblocking idle schedulers

-- Put executing scheduler to sleep.
blockSched :: IO ()
blockSched = getIdleSchedsSem >>= Sem.wait


-- Wake up 'n' sleeping schedulers.
wakeupSched :: Int -> IO ()
wakeupSched n = getIdleSchedsSem >>= replicateM_ n . Sem.signal


-----------------------------------------------------------------------------
-- spark selection policies

-- Local spark selection policy (pick sparks from back of queue),
-- starting from radius 'r' and and rippling outwords;
-- the scheduler ID may be used for logging.
selectLocalSpark :: Int -> Dist -> IO (Maybe (Spark, Dist, Priority))
selectLocalSpark schedID !r = do
  pool <- getPool r
  maybe_spark <- dequeueTaskIO pool
  case maybe_spark of
    Just (p, spark)     -> return $ Just (spark, r, p)       -- return spark
    Nothing | r == one  -> return Nothing                    -- pools empty
            | otherwise -> selectLocalSpark schedID (mul2 r) -- ripple out


-- Remote spark selection policy (pick sparks from front of queue),
-- starting from radius 'r0' and rippling outwords, but only if the pools
-- hold at least 'minSched' sparks in total;
-- schedID (expected to be msg handler ID 0) may be used for logging.
-- TODO: Track total number of sparks in pools more effectively.
selectRemoteSpark :: Int -> Dist -> IO (Maybe (Spark, Dist, Priority))
selectRemoteSpark _schedID r0 = do
  may <- maySCHEDULE
  if may
    then pickRemoteSpark r0
    else return Nothing
      where
        pickRemoteSpark :: Dist -> IO (Maybe (Spark, Dist, Priority))
        pickRemoteSpark !r = do
          pool <- getPool r
          maybe_spark <- dequeueTaskIO pool
          case maybe_spark of
            Just (p,spark)      -> return $ Just (spark, r, p)  -- return spark
            Nothing | r == one  -> return Nothing            -- pools empty
                    | otherwise -> pickRemoteSpark (mul2 r)  -- ripple out


-- Returns True iff total number of sparks in pools is at least 'minSched'.
maySCHEDULE :: IO Bool
maySCHEDULE = do
  min_sched <- getMinSched
  r_min <- getMinDistIO
  checkPools r_min min_sched one
    where
      checkPools :: Dist -> Int -> Dist -> IO Bool
      checkPools r_min !min_sparks !r = do
        pool <- getPool r
        sparks <- sizeIO pool
        let min_sparks' = min_sparks - sparks
        if min_sparks' <= 0
          then return True
          else if r == r_min
            then return False
            else checkPools r_min min_sparks' (div2 r)


-----------------------------------------------------------------------------
-- access to spark pool

-- Get a spark from the back of a spark pool with minimal radius, if any exists;
-- possibly send a FISH message and update stats (ie. count sparks converted);
-- the scheduler ID argument may be used for logging.
getLocalSpark :: Int -> IO (Maybe (Spark))
getLocalSpark schedID = do
  -- select local spark, starting with smallest radius
  r_min <- getMinDistIO
  maybe_spark <- selectLocalSpark schedID r_min
  case maybe_spark of
    Nothing         -> do
      sendFISH zero
      return Nothing
    Just (spark, r, p) -> do
      useLowWatermark <- useLowWatermarkOptimisation . sConf <$> getRTSState
      when useLowWatermark $ sendFISH r

      getSparkConvCtr >>= incCtr
      debug dbgSpark $
        "(spark converted)"

      return $ Just spark


-- Put a new spark at the back of the spark pool at radius 'r', wake up
-- 1 sleeping scheduler, and update stats (ie. count sparks generated locally);
-- the scheduler ID argument may be used for logging.
putLocalSpark :: Int -> Dist -> Spark -> IO ()
putLocalSpark _schedID r spark = putLocalSparkWithPrio _schedID r 0 spark

putLocalSparkWithPrio :: Int -> Dist -> Priority -> Spark -> IO ()
putLocalSparkWithPrio _schedID r p spark = do
  pool <- getPool r
  enqueueTaskIO pool p spark
  wakeupSched 1
  getSparkGenCtr >>= incCtr
  debug dbgSpark $
    "(spark created)"


-- Put received spark at the back of the spark pool at radius 'r', wake up
-- 1 sleeping scheduler, and update stats (ie. count sparks received);
-- schedID (expected to be msg handler ID 0) may be used for logging.
putRemoteSpark :: Int -> Dist -> Spark -> IO ()
putRemoteSpark _schedID r spark = putRemoteSparkWithPrio _schedID r 0 spark

putRemoteSparkWithPrio :: Int -> Dist -> Priority -> Spark -> IO ()
putRemoteSparkWithPrio _schedID r p spark = do
  pool <- getPool r
  enqueueTaskIO pool p spark
  wakeupSched 1
  getSparkRcvdCtr >>= incCtr

-----------------------------------------------------------------------------
-- HdpH messages (peer to peer)

-- 5 different types of messages dealing with fishing and pushing sparks
data Msg =   TERM        -- termination message (broadcast from root and back)
               !Node       -- root node
           | FISH        -- thief looking for work
               !Node       -- thief
               [Node]      -- targets already visited
               [Node]      -- remaining candidate targets
               [Node]      -- remaining primary source targets
               !Bool       -- True iff FISH may be forwarded to primary source
           | NOWORK      -- reply to thief's FISH (when there is no work)
           | SCHEDULE    -- reply to thief's FISH (when there is work)
                Spark   -- spark
               !Dist       -- spark's radius
               !Priority   -- spark's priority
               !Node       -- victim
           | PUSH        -- eagerly pushing work
                Spark    -- spark

-- Invariants for 'FISH thief avoid candidates sources fwd :: Msg':
-- * Lists 'candidates' and 'sources' are sorted in order of ascending
--   distance from 'thief'.
-- * Lists 'avoid', 'candidates' and 'sources' are sets (ie. no duplicates).
-- * Sets 'avoid', 'candidates' and 'sources' are pairwise disjoint.
-- * At the thief, a FISH message is launched with empty sets 'avoid' and
--   'sources', and at most 'maxHops' 'candidates'. As the message is being
--   forwarded, the cardinality of the sets 'avoid', 'candidates' and 'sources'
--   combined will never exceeed 2 * 'maxHops' + 1. This should be kept in mind
--   when choosing 'maxHops', to ensure that FISH messages stay small (ie. fit
--   into one packet).

-- Show instance (mainly for debugging)
instance Show Msg where
  showsPrec _ (TERM root)                = showString "TERM(" . shows root .
                                           showString ")"
  showsPrec _ (FISH thief avoid candidates sources fwd)
                                         = showString "FISH(" . shows thief .
                                           showString "," . shows avoid .
                                           showString "," . shows candidates .
                                           showString "," . shows sources .
                                           showString "," . shows fwd .
                                           showString ")"
  showsPrec _ (NOWORK)                   = showString "NOWORK"
  showsPrec _ (SCHEDULE _spark r p victim)
                                        = showString "SCHEDULE(_," . shows r .
                                          showString "," . shows p.
                                          showString "," . shows victim .
                                          showString ")"
  showsPrec _ (PUSH _spark)             = showString "PUSH(_)"


instance NFData Msg where
  rnf (TERM _root)                                = ()
  rnf (FISH _thief avoid candidates sources _fwd) = rnf avoid `seq`
                                                    rnf candidates `seq`
                                                    rnf sources
  rnf (NOWORK)                                    = ()
  rnf (SCHEDULE spark _r _p _victim)              = rnf spark
  rnf (PUSH spark)                                = rnf spark


-- TODO: Derive this instance.
instance Serialize Msg where
  put (TERM root)               = Data.Serialize.put (0 :: Word8) >>
                                  Data.Serialize.put root
  put (FISH thief avoid candidates sources fwd)
                                = Data.Serialize.put (1 :: Word8) >>
                                  Data.Serialize.put thief >>
                                  Data.Serialize.put avoid >>
                                  Data.Serialize.put candidates >>
                                  Data.Serialize.put sources >>
                                  Data.Serialize.put fwd
  put (NOWORK)                  = Data.Serialize.put (2 :: Word8)
  put (SCHEDULE spark r p victim)
                                = Data.Serialize.put (3 :: Word8) >>
                                  Data.Serialize.put spark >>
                                  Data.Serialize.put r >>
                                  Data.Serialize.put p >>
                                  Data.Serialize.put victim
  put (PUSH spark)              = Data.Serialize.put (4 :: Word8) >>
                                  Data.Serialize.put spark

  get = do tag <- Data.Serialize.get
           case tag :: Word8 of
             0 -> do root <- Data.Serialize.get
                     return $ TERM root
             1 -> do thief      <- Data.Serialize.get
                     avoid      <- Data.Serialize.get
                     candidates <- Data.Serialize.get
                     sources    <- Data.Serialize.get
                     fwd        <- Data.Serialize.get
                     return $ FISH thief avoid candidates sources fwd
             2 -> do return $ NOWORK
             3 -> do spark  <- Data.Serialize.get
                     r      <- Data.Serialize.get
                     p      <- Data.Serialize.get
                     victim <- Data.Serialize.get
                     return $ SCHEDULE spark r p victim
             4 -> do spark  <- Data.Serialize.get
                     return $ PUSH spark
             _ -> error "panic in instance Serialize Msg: tag out of range"


-----------------------------------------------------------------------------
-- fishing and the like

-- Returns True iff FISH message should be sent;
-- assumes spark pools at radius < r_min are empty, and
-- all pools are empty if r_min == zero.
goFISHing :: Dist -> IO Bool
goFISHing r_min = do
  fishingFlag <- getFishingFlag
  isFishing   <- readFlag fishingFlag
  isSingle    <- singleNode
  max_fish    <- getMaxFish
  if isFishing || isSingle || max_fish < 0
    then do
      -- don't fish if * a FISH is outstanding, or
      --               * there is only one node, or
      --               * fishing is switched off
      return False
    else do
      -- check total number of sparks is above low watermark
      if r_min == zero
        then return True
        else checkPools max_fish r_min
          where
            checkPools :: Int -> Dist -> IO Bool
            checkPools min_sparks r = do
              pool <- getPool r
              sparks <- sizeIO pool
              let min_sparks' = min_sparks - sparks
              if min_sparks' < 0
                then return True
                else if r == one
                  then return $ min_sparks' == 0
                  else checkPools min_sparks' (mul2 r)


-- Send a FISH message, but only if there is no FISH outstanding and the total
-- number of sparks in the pools is less or equal to the 'maxFish' parameter;
-- assumes pools at radius < r_min are empty, and all pools are empty if
-- r_min == zero; the FISH victim is one of minimal distance, selected
-- according to the 'selectFirstVictim' policy.
sendFISH :: Dist -> IO ()
sendFISH r_min = do
  -- check whether a FISH message should be sent
  go <- goFISHing r_min
  when go $ do
    -- set flag indicating that FISH is going to be sent
    fishingFlag <- getFishingFlag
    ok <- setFlag fishingFlag
    when ok $ do
      -- flag was clear before: go ahead sending FISH
      -- select victim
      thief <- Comm.myNode
      max_hops <- getMaxHops
      candidates <- randomCandidates max_hops

      maybe_src <- readSparkOrigHist

      -- compose FISH message
      let (target, msg) =
            case maybe_src of
              Just src -> (src, FISH thief [] candidates [] False)
              Nothing  ->
                case candidates of
                  cand:cands -> (cand, FISH thief [] cands [] True)
                  []         -> (thief, NOWORK)  -- no candidates --> NOWORK
      -- send FISH (or NOWORK) message
      debug dbgMsgSend $ let msg_size = BS.length (encodeLazy msg) in
        show msg ++ " ->> " ++ show target ++ " Length: " ++ show msg_size
      Comm.send target $ encodeLazy msg
      case msg of
        FISH _ _ _ _ _ -> getFishSentCtr >>= incCtr  -- update stats
        _              -> return ()

-- Return up to 'n' random candidates drawn from the equidistant bases,
-- excluding the current node and sorted in order of ascending distance.
randomCandidates :: Int -> IO [Node]
randomCandidates n = do
  bases <- reverse . DistMap.toDescList <$> getEquiDistBasesIO
  let universes = [[(r, p) | (p, _) <- tail_basis] | (r, _:tail_basis) <- bases]
  map snd . sortBy (comparing fst) <$> uniqRandomsRR n universes


-- Dispatch FISH, SCHEDULE and NOWORK messages to their respective handlers.
dispatch :: Msg -> IO ()
dispatch msg@(FISH _ _ _ _ _)   = handleFISH msg
dispatch msg@(SCHEDULE _ _ _ _)   = handleSCHEDULE msg
dispatch msg@(NOWORK)           = handleNOWORK msg
dispatch msg = error $ "HdpH.Internal.Sparkpool.dispatch: " ++
                       show msg ++ " unexpected"


-- Handle a FISH message; replies
-- * with SCHEDULE if pool has enough sparks, or else
-- * with NOWORK if FISH has travelled far enough, or else
-- * forwards FISH to a candidate target or a primary source of work.
handleFISH :: Msg -> IO ()
handleFISH msg@(FISH thief _avoid _candidates _sources _fwd) = do
  me <- Comm.myNode
  maybe_spark <- selectRemoteSpark 0 (dist thief me)
  case maybe_spark of
    Just (spark, r, prio) -> do -- compose and send SCHEDULE
      let scheduleMsg = SCHEDULE spark r prio me
      debug dbgMsgSend $ let msg_size = BS.length (encodeLazy scheduleMsg) in
        show scheduleMsg ++ " ->> " ++ show thief ++ " Length: " ++ show msg_size
      Comm.send thief $ encodeLazy scheduleMsg
    Nothing -> do
      maybe_src <- readSparkOrigHist
      -- compose FISH message to forward
      let (target, forwardMsg) = forwardFISH me maybe_src msg
      -- send message
      debug dbgMsgSend $ let msg_size = BS.length (encodeLazy forwardMsg) in
        show forwardMsg ++ " ->> " ++ show target ++ " Length: " ++ show msg_size
      Comm.send target $ encodeLazy forwardMsg
handleFISH _ = error "panic in handleFISH: not a FISH message"

-- Auxiliary function, called by 'handleFISH' when there is nought to schedule.
-- Constructs a forward and selects a target, or constructs a NOWORK reply.
forwardFISH :: Node -> Maybe Node -> Msg -> (Node, Msg)
forwardFISH me _          (FISH thief avoid candidates sources False) =
  dispatchFISH (FISH thief (me:avoid) candidates sources False)
forwardFISH me Nothing    (FISH thief avoid candidates sources _)     =
  dispatchFISH (FISH thief (me:avoid) candidates sources False)
forwardFISH me (Just src) (FISH thief avoid candidates sources True)  =
  spineList sources' `seq`
  dispatchFISH (FISH thief (me:avoid) candidates sources' False)
    where
      sources' = if src `elem` thief:(sources ++ avoid ++ candidates)
                   then sources  -- src is already known
                   else insertBy (comparing $ dist thief) src sources
forwardFISH _ _ _ = error "panic in forwardFISH: not a FISH message"

-- Auxiliary function, called by 'forwardFISH'.
-- Extracts target and message from preliminary FISH message.
dispatchFISH :: Msg -> (Node, Msg)
dispatchFISH (FISH thief avoid' candidates sources' _) =
  case (candidates, sources') of
    ([],         [])       -> (thief, NOWORK)
    (cand:cands, [])       -> (cand,  FISH thief avoid' cands []   True)
    ([],         src:srcs) -> (src,   FISH thief avoid' []    srcs False)
    (cand:cands, src:srcs) ->
      if dist thief cand < dist thief src
        then -- cand is closest to thief
             (cand, FISH thief avoid' cands      sources' True)
        else -- otherwise prefer src
             (src,  FISH thief avoid' candidates srcs     False)
dispatchFISH _ = error "panic in dispatchFISH: not a FISH message"


-- Handle a SCHEDULE message;
-- * puts received spark at the back of the appropriate spark pool,
-- * wakes up 1 sleeping scheduler,
-- * records spark sender and updates stats, and
-- * clears the "FISH outstanding" flag.
handleSCHEDULE :: Msg -> IO ()
handleSCHEDULE (SCHEDULE spark r p victim) = do
  -- put spark into pool, wakeup scheduler and update stats
  putRemoteSparkWithPrio 0 r p spark
  -- record source of spark
  setSparkOrigHist victim
  -- clear FISHING flag
  void $ getFishingFlag >>= clearFlag
handleSCHEDULE _ = error "panic in handleSCHEDULE: not a SCHEDULE message"


-- Handle a NOWORK message;
-- clear primary fishing target, then asynchronously, after a random delay,
-- clear the "FISH outstanding" flag and wake one scheduler (if some are
-- sleeping) to resume fishing.
-- Rationale for random delay: to prevent FISH flooding when there is
--   (almost) no work.
handleNOWORK :: Msg -> IO ()
handleNOWORK NOWORK = do
  clearSparkOrigHist
  fishingFlag   <- getFishingFlag
  noWorkServer  <- getNoWorkServer
  idleSchedsSem <- getIdleSchedsSem
  minDelay      <- getMinFishDly
  maxDelay      <- getMaxFishDly
  -- compose delay and clear flag action
  let action = do -- random delay
                  delay <- randomRIO (minDelay, max minDelay maxDelay)
                  threadDelay delay
                  -- clear fishing flag
                  atomicModifyIORef fishingFlag $ const (False, ())
                  -- wakeup 1 sleeping scheduler (to fish again)
                  Sem.signal idleSchedsSem
  -- post action request to server
  reqAction noWorkServer action
handleNOWORK _ = error "panic in handleNOWORK: not a NOWORK message"


-----------------------------------------------------------------------------
-- auxiliary stuff

-- walks along a list, forcing its spine
spineList :: [a] -> ()
spineList []     = ()
spineList (_:xs) = spineList xs




-- Returns up to 'n' unique random elements from the given list of 'universes',
-- which are cycled through in a round robin fashion.
uniqRandomsRR :: Int -> [[a]] -> IO [a]
uniqRandomsRR n universes =
  if n <= 0
    then return []
    else case universes of
      []         -> return []
      []:univs   -> uniqRandomsRR n univs
      univ:univs -> do
        i <- randomRIO (0, length univ - 1)
        let (prefix, x:suffix) = splitAt i univ
        xs <- uniqRandomsRR (n - 1) (univs ++ [prefix ++ suffix])
        return (x:xs)


-- debugging
debug :: Int -> String -> IO ()
debug level message = Location.debug level message
