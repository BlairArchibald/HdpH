-- HdpH programming interface
--
-- Author: Patrick Maier, Rob Stewart
-----------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving #-}  -- for 'GIVar' and 'Node'
{-# LANGUAGE FlexibleInstances #-}           -- for some 'ToClosure' instances

{-# LANGUAGE TemplateHaskell #-}             -- for 'mkClosure', etc.

module Control.Parallel.HdpH
  ( -- $Intro

    -- * Par monad
    Par,
    -- $Par_monad
    runParIO_,    -- :: RTSConf -> Par () -> IO ()
    runParIO,     -- :: RTSConf -> Par a -> IO (Maybe a)

    -- * Operations in the Par monad
    -- $Par_ops
    done,      -- :: Par a
--    yield,     -- :: Par ()  -- Nice to have but isn't implemented yet
    myNode,    -- :: Par Node
    allNodes,  -- :: Par [Node]
    equiDist,  -- :: Dist -> Par [(Node,Int)]
    allNodesWithin,  -- :: Dist -> Par (Closure [Node])
    time,      -- :: Par a -> Par (a, NominalDiffTime)
    io,        -- :: IO a -> Par a
    eval,      -- :: a -> Par a
    force,     -- :: (NFData a) => a -> Par a
    forkHi,    -- :: Par () -> Par ()
    fork,      -- :: Par () -> Par ()
    spark,     -- :: Dist -> Closure (Par ()) -> Par ()
    -- :: Dist -> Priority -> Closure (Par ()) -> Par ()
    sparkWithPrio,
    pushTo,    -- :: Closure (Par ()) -> Node -> Par ()
    spawn,     -- :: Dist -> Closure (Par (Closure a)) -> Par (IVar (Closure a))
    spawnAt,   -- :: Node -> Closure (Par (Closure a)) -> Par (IVar (Closure a))
    -- :: Dist -> Priority -> Closure (Par (Closure a)) -> Par (IVar (Closure a))
    spawnWithPrio,
    new,       -- :: Par (IVar a)
    put,       -- :: IVar a -> a -> Par ()
    get,       -- :: IVar a -> Par a
    tryGet,    -- :: IVar a -> Par (Maybe a)
    probe,     -- :: IVar a -> Par Bool
    glob,      -- :: IVar (Closure a) -> Par (GIVar (Closure a))
    rput,      -- :: GIVar (Closure a) -> Closure a -> Par ()
    tryRPut,      -- :: GIVar (Closure a) -> Closure a -> Par ()
    stub,      -- :: Par () -> Par ()

    -- * Locations and distance metric
    Node,
    dist,      -- :: Node -> Node -> Dist

    -- * Local and global IVars
    IVar,
    GIVar,
    at,        -- :: GIVar a -> Node

    -- * Explicit Closures
    module Control.Parallel.HdpH.Closure,

    -- * Distances
    module Control.Parallel.HdpH.Dist,

    -- * Runtime system configuration
    module Control.Parallel.HdpH.Conf,

    -- * This module's Static declaration
    declareStatic
  ) where

import Prelude hiding (error, lookup)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData, deepseq)
import Control.Monad (when, void, forM)
import Data.Functor ((<$>))
import Data.Hashable (Hashable)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Monoid (mconcat)
import Data.Serialize (Serialize)
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)

import Control.Parallel.HdpH.Conf                            -- re-export whole module
import Control.Parallel.HdpH.Closure hiding (declareStatic)  -- re-export almost whole module
import qualified Control.Parallel.HdpH.Closure as Closure (declareStatic)
import Control.Parallel.HdpH.Dist                            -- re-export whole module
import qualified Control.Parallel.HdpH.Internal.Comm as Comm
       (myNode, isRoot, equiDistBases)
import qualified Control.Parallel.HdpH.Internal.Data.DistMap as DistMap
       (lookup)
import qualified Control.Parallel.HdpH.Internal.IVar as IVar (IVar, GIVar)
import Control.Parallel.HdpH.Internal.IVar
       (hostGIVar, newIVar, putIVar, getIVar, pollIVar, probeIVar,
        globIVar, putGIVar, tryPutGIVar)
import qualified Control.Parallel.HdpH.Internal.Location as Location
       (Node, debug, dbgStaticTab)
import qualified Control.Parallel.HdpH.Internal.Topology as Topology
       (dist)
import Control.Parallel.HdpH.Internal.Scheduler
       (forkStub, schedulerID, mkThread, execThread, sendPUSH)
import qualified Control.Parallel.HdpH.Internal.Scheduler as Scheduler (run_)
import Control.Parallel.HdpH.Internal.Sparkpool (putLocalSpark,
                                                 putLocalSparkWithPrio)
import Control.Parallel.HdpH.Internal.Threadpool (putThread, putThreads)
import Control.Parallel.HdpH.Internal.Type.Par
       (Par, mkPar, Thread(Atom), ThreadCont(ThreadCont, ThreadDone), unPar, ask)
import Control.Parallel.HdpH.Internal.Data.PriorityWorkQueue (Priority)
import Control.Parallel.HdpH.Internal.State.RTSState (rtsState, RTSState(sTpools))

-----------------------------------------------------------------------------
-- $Intro
-- HdpH (/Haskell distributed parallel Haskell/) is a Haskell DSL for shared-
-- and distributed-memory parallelism, implemented entirely in Haskell
-- (as supported by the GHC). HdpH is described in the following paper:
--
-- P. Maier, P. W. Trinder.
-- /Implementing a High-level Distributed-Memory Parallel Haskell in Haskell/.
-- IFL 2011.
--
-- HdpH executes programs written in a monadic embedded DSL for shared-
-- and distributed-memory parallelism.
-- HdpH operates a distributed runtime system, scheduling tasks
-- either explicitly (controled by the DSL) or implicitly (by work stealing).
-- The runtime system distinguishes between nodes and schedulers.
-- A /node/ is an OS process running HdpH (that is, a GHC-compiled executable
-- built on top of the HdpH library), whereas a /scheduler/ is a Haskell IO
-- thread executing HdpH expressions (that is, 'Par' monad computation).
-- As a rule of thumb, a node should correspond to a machine in a network,
-- and a scheduler should correspond to a core in a machine.
--
-- The semantics of HdpH was developed with fault tolerance in mind (though
-- this version of HdpH is not yet fault tolerant). In particular, HdpH
-- allows the replication of computations, and the racing of computations
-- against each other. The price to pay for these features is that HdpH
-- cannot enforce determinism.


-----------------------------------------------------------------------------
-- abstract locations and distance metric

-- | A 'Node' identifies a node (that is, an OS process running HdpH).
-- A 'Node' should be thought of as an abstract identifier which instantiates
-- the classes 'Eq', 'Ord', 'Hashable', 'Show', 'NFData' and 'Serialize'.
newtype Node = Node Location.Node
                 deriving (Eq, Ord, Hashable, NFData, Serialize)

-- Show instance (mainly for debugging)
instance Show Node where
  showsPrec _ (Node n) = showString "Node:". shows n


-- | Ultrametric distance between nodes.
dist :: Node -> Node -> Dist
dist (Node n1) (Node n2) = Topology.dist n1 n2


-----------------------------------------------------------------------------
-- abstract IVars and GIVars

-- | An IVar is a write-once one place buffer.
-- IVars are abstract; they can be accessed and manipulated only by
-- the operations 'put', 'get', 'tryGet', 'probe' and 'glob'.
newtype IVar a = IVar (IVar.IVar a)


-- | A GIVar (short for /global/ IVar) is a globally unique handle referring
-- to an IVar.
-- Unlike IVars, GIVars can be compared and serialised.
-- They can also be written to remotely by the operation 'rput'.
newtype GIVar a = GIVar (IVar.GIVar a)
                  deriving (Eq, Ord, NFData, Serialize)

-- Show instance (mainly for debugging)
instance Show (GIVar a) where
  showsPrec _ (GIVar gv) = showString "GIVar:" . shows gv


-- | Returns the node hosting the IVar referred to by the given GIVar.
-- This function being pure implies that IVars cannot migrate between nodes.
at :: GIVar a -> Node
at (GIVar gv) = Node $ hostGIVar gv


-----------------------------------------------------------------------------
-- abstract runtime system (don't export)

-- | Eliminate the 'RTS' monad down to 'IO' by running the given 'action';
-- aspects of the RTS's behaviour are controlled by the respective parameters
-- in the 'conf' argument.
runRTS_ :: RTSConf -> IO () -> IO ()
runRTS_ = Scheduler.run_

-- | Return True iff this node is the root node.
isMainRTS :: IO Bool
isMainRTS = Comm.isRoot

-----------------------------------------------------------------------------
-- atomic Par actions (not to be exported)

-- The following actions lift RTS actions to the Par monad;
-- the actions are actually functions expecting a Boolean that is True
-- iff the action is executed by a high priority thread.

-- lifting RTS action into the Par monad; don't export (usually)
-- thread :: Bool -> IO ThreadCont
-- ThreadCont :: Cont [Thread] [Thread] | Done?
atom :: (Bool -> IO a) -> Par a
{-# INLINE atom #-}
atom m = mkPar $ \s c -> Atom $ \hi -> m hi >>= \a -> return $ ThreadCont [] (c a)

-- lifting RTS action into the Par monad, potentially injecting some
-- high priority threads; don't export
atomMayInjectHi :: (Bool -> IO ([Thread], a)) -> Par a
{-# INLINE atomMayInjectHi #-}
atomMayInjectHi m =
  mkPar $ \s c -> Atom $ \ hi -> m hi >>= \ (hts, x) ->
                              return $ ThreadCont hts $ c x

-- lifting an RTS action that may potentially stop into the Par monad;
-- the action is expected to return Nothing if it did stop; note that
-- the action itself is responsible for capturing the continuation c
-- to continue later on (if it is suspended rather than terminating)
atomMayStop :: ((a -> Thread) -> Bool -> IO (Maybe a)) -> Par a
{-# INLINE atomMayStop #-}
atomMayStop m =
  mkPar $ \s c -> Atom $ \ hi -> m c hi >>=
                              maybe (return $ ThreadDone [])
                                    (return . ThreadCont [] . c)


-----------------------------------------------------------------------------
-- eliminate the Par monad

-- | Eliminate the 'Par' monad by converting the given 'Par' action 'p'
-- into an 'RTS' action (to be executed as a low-priority thread on any
-- one node of the distributed runtime system).
runPar :: Par a -> IO a
runPar p = do -- create an empty MVar expecting the result of action 'p'
              res <- newEmptyMVar

              -- fork 'p', combined with a write to above MVar;
              -- note that the starter thread (ie the 'fork') runs outwith
              -- any scheduler (and terminates quickly); the forked action
              -- (ie. 'p >>= ...') runs in a scheduler, however.

              -- Get the threadpools from the state?
              tps <- sTpools <$> readIORef rtsState
              execThread $ mkThread tps $ fork (p >>= io . putMVar res)

              -- block waiting for result
              takeMVar res


-- | Eliminates the 'Par' monad by executing the given parallel computation 'p',
-- including setting up and initialising a distributed runtime system
-- according to the configuration parameter 'conf'.
-- This function lives in the IO monad because 'p' may be impure,
-- for instance, 'p' may exhibit non-determinism.
-- Caveat: Though the computation 'p' will only be started on a single root
-- node, 'runParIO_' must be executed on every node of the distributed runtime
-- system du to the SPMD nature of HdpH.
runParIO_ :: RTSConf -> Par () -> IO ()
runParIO_ conf p =
  runRTS_ conf $ do isMain <- isMainRTS
                    when isMain $ do
                      -- print Static table
                      Location.debug Location.dbgStaticTab $ unlines $
                        "" : map ("  " ++) showStaticTable
                      runPar p


-- | Convenience: variant of 'runParIO_' which does return a result.
-- Caveat: The result is only returned on the root node; all other nodes
-- return 'Nothing'.
runParIO :: RTSConf -> Par a -> IO (Maybe a)
runParIO conf p = do res <- newIORef Nothing
                     runParIO_ conf (p >>= io . writeIORef res . Just)
                     readIORef res


-----------------------------------------------------------------------------
-- $Par_ops
-- These operations form the HdpH DSL, a low-level API of for parallel
-- programming across shared- and distributed-memory architectures.
-- For a more high-level API see module "Control.Parallel.HdpH.Strategies".

-- | Terminates the current thread.
done :: Par a
{-# INLINE done #-}
done = atomMayStop $ const $ const $ return Nothing

-- | Yield low priority current thread (ie. put it back in the spark pool).
-- warning: will not work well because it puts the thread back into the pool
--          and then immediately schedules the same thread again. to make it
--          work, should put thread into threadpool of scheduler 0, or at the
--          back of own threadpool.
-- yield :: Par ()
-- {-# inline yield #-}

--                                   then return $ Just ()
--                                   else do ask >>= \tp -> putThread tp $ c ()
--                                           return Nothing

-- | Times a Par action.
time :: Par a -> Par (a, NominalDiffTime)
time action = do
  t0 <- io getCurrentTime
  x <- action
  t1 <- io getCurrentTime
  return (x, diffUTCTime t1 t0)

-- | Evaluates its argument to weak head normal form.
eval :: a -> Par a
{-# INLINE eval #-}
eval x = atom $ const $ x `seq` return x

-- | Evaluates its argument to normal form (as defined by 'NFData' instance).
force :: (NFData a) => a -> Par a
{-# INLINE force #-}
force x = atom $ const $ x `deepseq` return x

-- | Evaulate an IO action inside the par monad
io :: IO a -> Par a
io i = atom (\_ -> i)

-- | Returns the node this operation is currently executed on.
myNode :: Par Node
{-# INLINE myNode #-}
myNode = Node <$> (atom $ const $ Comm.myNode)

-- | Returns a list of all nodes currently forming the distributed
--   runtime system, where the head of the list is the current node.
--   This operation may query all nodes, which may incur significant latency.
allNodes :: Par [Node]
allNodes = unClosure <$> allNodesWithin one

-- | Returns a list of all nodes within the given distance around the
--   current node (which is the head of the list).
allNodesWithin :: Dist -> Par (Closure [Node])
allNodesWithin r = do
  let half_r = div2 r
  (this,near_size):rest_basis <- equiDist r
  vs <- forM rest_basis $ \ (q,n) -> do
          v <- new
          if n > 1
            then do -- remote recurive call
                    gv <- glob v
                    pushTo $(mkClosure [| allNodesWithin_abs (half_r, gv) |]) q
            else put v $ toClosure [q]
          return v
  near_nodes <-
    if near_size > 1
      then unClosure <$> allNodesWithin half_r  -- local recursive call
      else return [this]
  rest_nodes <- mapM (fmap unClosure . get) vs
  return $ toClosure $ concat (near_nodes : rest_nodes)

allNodesWithin_abs :: (Dist, GIVar (Closure [Node])) -> Thunk (Par ())
allNodesWithin_abs (half_r, gv) = Thunk $ allNodesWithin half_r >>= rput gv

-- | Returns an equidistant basis of radius 'r' around the current node.
--   By convention, the head of the list is the current node.
equiDist :: Dist -> Par [(Node,Int)]
equiDist r = map (\ (p, n) -> (Node p, n)) . DistMap.lookup r <$>
               (atom $ const $ Comm.equiDistBases)

-- | Creates a new high-priority thread, to be executed immediately.
forkHi :: Par () -> Par ()
{-# INLINE forkHi #-}
forkHi comp = ask >>= \s -> atomMayInjectHi (\_ -> return ([mkThread s comp], ()))

-- | Creates a new low-priority thread, to be executed on the current node.
fork :: Par () -> Par ()
{-# INLINE fork #-}
fork cmp = ask >>= \s -> atom . const $ putThread s (mkThread s cmp)

-- | Creates a spark, to be available for work stealing.
-- The spark may be converted into a thread and executed locally, or it may
-- be stolen by another node and executed there.
spark :: Dist -> Closure (Par ()) -> Par ()
{-# INLINE spark #-}
spark r clo = ask >>= \s -> atom $ const $ schedulerID s >>= \ i -> putLocalSpark i r clo

-- | Creates a new spark with the given priority
sparkWithPrio :: Dist -> Priority -> Closure (Par ()) -> Par ()
{-# INLINE sparkWithPrio #-}
sparkWithPrio r p clo = ask >>= \s -> atom $ const $ schedulerID s >>= \ i -> putLocalSparkWithPrio i r p clo

-- | Pushes a computation to the given node, where it is eagerly converted
-- into a thread and executed.
pushTo :: Closure (Par ()) -> Node -> Par ()
{-# INLINE pushTo #-}
pushTo clo (Node n) = ask >>= \s -> atom $ const $ sendPUSH s clo n

-- | Included for compatibility with PLDI paper;
--   Sparkpool should be redesigned to avoid use 'mkClosure' here
spawn :: Dist -> Closure (Par (Closure a)) -> Par (IVar (Closure a))
spawn r clo = spawnWithPrio r 0 clo

-- Spawn a task with a given priority
spawnWithPrio :: Dist
              -> Priority
              -> Closure (Par (Closure a))
              -> Par (IVar (Closure a))
spawnWithPrio r p clo = do
  v  <- new
  gv <- glob v
  sparkWithPrio r p $(mkClosure [| spawn_abs (clo, gv) |])
  return v

-- | Included for compatibility with PLDI paper;
--   Message handler should be redesigned to avoid use 'mkClosure' here
spawnAt :: Node -> Closure (Par (Closure a)) -> Par (IVar (Closure a))
spawnAt q clo = do
  v <- new
  gv <- glob v
  pushTo $(mkClosure [| spawn_abs (clo, gv) |]) q
  return v

spawn_abs :: (Closure (Par (Closure a)), GIVar (Closure a)) -> Thunk (Par ())
spawn_abs (clo, gv) = Thunk $ unClosure clo >>= rput gv

-- | Creates a new empty IVar.
new :: Par (IVar a)
{-# INLINE new #-}
new = IVar <$> (atom $ const $ newIVar)

-- | Writes to given IVar (without forcing the value written).
put :: IVar a -> a -> Par ()
{-# INLINE put #-}
put (IVar v) a = ask >>= \s ->
  atomMayInjectHi . const $ putIVar v a >>= \(hts, lts) -> putThreads s lts >> return (hts, ())

-- | Reads from given IVar; blocks if the IVar is empty.
get :: IVar a -> Par a
{-# INLINE get #-}
get (IVar v) = atomMayStop $ \c hi -> getIVar hi v c
-- atomMayStop :: ((a -> Thread) -> Bool -> IO (Maybe a)) -> Par a

-- | Reads from given IVar; does not block but returns 'Nothing' if IVar empty.
tryGet :: IVar a -> Par (Maybe a)
{-# INLINE tryGet #-}
tryGet (IVar v) = atom $ const $ pollIVar v

-- | Tests whether given IVar is empty or full; does not block.
probe :: IVar a -> Par Bool
{-# INLINE probe #-}
probe (IVar v) = atom $ const $ probeIVar v

-- | Globalises given IVar, returning a globally unique handle;
-- this operation is restricted to IVars of 'Closure' type.
glob :: IVar (Closure a) -> Par (GIVar (Closure a))
{-# INLINE glob #-}
glob (IVar v) = do
  s <- ask
  GIVar <$> (atom $ const $ schedulerID s >>= \ i -> globIVar i v)

-- | Writes to (possibly remote) IVar denoted by given global handle;
-- this operation is restricted to write values of 'Closure' type.
rput :: GIVar (Closure a) -> Closure a -> Par ()
{-# INLINE rput #-}
rput gv clo = pushTo $(mkClosure [| rput_abs (gv, clo) |]) (at gv)

-- write to locally hosted global IVar; don't export
rput_abs :: (GIVar (Closure a), Closure a) -> Thunk (Par ())
{-# INLINE rput_abs #-}
rput_abs (GIVar gv, clo) = Thunk $ do
  s <- ask
  atomMayInjectHi $ const $
    schedulerID s >>= \ i ->
    putGIVar i gv clo >>= \ (hts, lts) ->
    putThreads s lts >>
    return (hts, ())

tryRPut :: GIVar (Closure a) -> Closure a -> Par (IVar (Closure Bool))
{-# INLINE tryRPut #-}
tryRPut gv clo = spawnAt (at gv) $(mkClosure [| tryRPut_abs (gv, clo) |])

-- write to locally hosted global IVar; don't export
tryRPut_abs :: (GIVar (Closure a), Closure a) -> Thunk (Par (Closure Bool))
{-# INLINE tryRPut_abs #-}
tryRPut_abs (GIVar gv, clo) = Thunk $ do
  s <- ask
  atomMayInjectHi $ const $
        schedulerID s >>= \ i ->
        tryPutGIVar i gv clo >>= \ (suc, hts, lts) ->
        putThreads s lts >>
        return (hts, toClosureBool suc)

toClosureBool :: Bool -> Closure Bool
toClosureBool b = $(mkClosure [| toClosureBool_abs b |])

toClosureBool_abs :: Bool -> Thunk Bool
toClosureBool_abs b = Thunk b

-- | Fork argument as stub to stand in for an external computing resource.
stub :: Par () -> Par ()
{-# INLINE stub #-}
stub comp = ask >>= \s -> atom . const . void $ forkStub s . const $ execThread (mkThread s comp)


-----------------------------------------------------------------------------
-- Static declaration (must be at end of module)

-- Empty splice; TH hack to make all environment abstractions visible.
$(return [])

instance ToClosure [Node] where locToClosure = $(here)

-- | Static declaration of Static deserialisers used in explicit Closures
-- created or imported by this module.
-- This Static declaration must be imported by every main module using HdpH.
-- The imported Static declaration must be combined with the main module's own
-- Static declaration and registered; failure to do so may abort the program
-- at runtime.
declareStatic :: StaticDecl
declareStatic = mconcat
  [Closure.declareStatic,
   declare (staticToClosure :: StaticToClosure [Node]),
   declare $(static 'toClosureBool_abs),
   declare $(static 'allNodesWithin_abs),
   declare $(static 'spawn_abs),
   declare $(static 'rput_abs),
   declare $(static 'tryRPut_abs)]
