-- Par monad and thread representation; types
--
-- Author: Patrick Maier
-----------------------------------------------------------------------------

module Control.Parallel.HdpH.Internal.Type.Par
  ( -- * Par monad, threads and sparks
    Par,
    mkPar,
    unPar,
    runPar,
    ask,
    Thread(..),
    ThreadCont(..),
    Spark       -- synonym: Spark m = Closure (ParM m ())
  ) where

import Prelude
import Control.Monad.Cont
import Control.Parallel.HdpH.Closure (Closure)

import Control.Parallel.HdpH.Internal.Data.Deque (DequeIO)

-----------------------------------------------------------------------------
-- Par monad, based on ideas from
--   [1] Claessen "A Poor Man's Concurrency Monad", JFP 9(3), 1999.
--   [2] Marlow et al. "A monad for deterministic parallelism". Haskell 2011.

-- 'ParM m' is a continuation monad, specialised to the return type 'Thread m';
-- 'm' abstracts a monad encapsulating the underlying state.
-- newtype ParM m a = Par { unPar :: (a -> Thread m) -> Thread m }

newtype ContR s r a = ContR { unPar :: s -> (a -> r) -> r }

instance Functor (ContR s r) where
  fmap f k = ContR $ \s c -> unPar k s (c . f)

instance Applicative (ContR s r) where
  pure  = return
  (<*>) = ap

instance Monad (ContR s r) where
  return a = ContR $ \s c -> c a
  f >>= k  = ContR $ \s c -> unPar f s $ \a -> unPar (k a) s c

ask :: ContR s r s
ask = ContR $ \s c -> c s

type Par a = ContR [(Int, DequeIO Thread)] (IO Thread) a

io :: IO a -> Par a
io x = ContR $ \s c -> join (fmap c x)

-- return action :: Par (IO a)

-- I guess we need to get a Par IO a somehow and then run inside it?

runPar :: Par a -> [(Int, DequeIO Thread)] -> (a -> IO Thread) -> IO Thread
runPar k tp f = unPar k tp f

mkPar :: (s -> (a -> r) -> r) -> ContR s r a
mkPar = ContR

-- A thread is a monadic action returning a ThreadCont (telling the scheduler
-- how to continue after executing the monadic action).
-- Note that [2] uses different model, a "Trace" GADT reifying the monadic
-- actions, which are then interpreted by the scheduler.
newtype Thread = Atom (Bool -> IO ThreadCont)

-- A ThreadCont either tells the scheduler to continue (constructor ThreadCont)
-- or to terminate the current thread (constructor ThreadDone).
-- In either case, the ThreadCont additionally provides a (possibly empty) list
-- of high priority threads, to be executed before any low priority threads.
data ThreadCont = ThreadCont ![Thread] (Thread)
                | ThreadDone ![Thread]


-- A spark is a 'Par' comp returning '()', wrapped into an explicit closure.
type Spark = Closure (Par ())
