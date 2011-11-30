-- Fibonacci numbers in HdpH
--
-- Visibility: HdpH test suite
-- Author: Patrick Maier <P.Maier@hw.ac.uk>
-- Created: 17 Jul 2011
--
-----------------------------------------------------------------------------

module Main where

import Prelude
import Control.Exception (evaluate)
import Control.Monad (when)
import Data.List (elemIndex, stripPrefix)
import Data.Maybe (fromJust)
import Data.Monoid (mconcat)
import System.Environment (getArgs)
import System.IO (stdout, stderr, hSetBuffering, BufferMode(..))
import System.Random (mkStdGen, setStdGen)

import qualified MP.MPI_ByteString as MPI
import HdpH (RTSConf(..), defaultRTSConf,
             Par, runParIO,
             force, fork, spark, new, get, put, glob, rput,
             Env, encodeEnv, decodeEnv,
             toClosure, unsafeMkClosure, unClosure,
             DecodeStatic, decodeStatic,
             Static, staticAs, declare, register)
import HdpH.Internal.Misc (timeIO)  -- for measuring runtime


-----------------------------------------------------------------------------
-- 'Static' declaration and registration

instance DecodeStatic Integer

registerStatic :: IO ()
registerStatic =
  register $ mconcat
    [declare dist_fib_Static,
     declare (decodeStatic :: Static (Env -> Integer))]


-----------------------------------------------------------------------------
-- sequential Fibonacci

fib :: Int -> Integer
fib n | n <= 1    = 1
      | otherwise = fib (n-1) + fib (n-2)


-----------------------------------------------------------------------------
-- parallel Fibonacci; shared memory

par_fib :: Int -> Int -> Par Integer
par_fib seqThreshold n
  | n <= k    = force $ fib n
  | otherwise = do v <- new
                   let job = par_fib seqThreshold (n - 1) >>=
                             force >>=
                             put v
                   fork job
                   y <- par_fib seqThreshold (n - 2)
                   x <- get v
                   force $ x + y
  where k = max 1 seqThreshold


-----------------------------------------------------------------------------
-- parallel Fibonacci; distributed memory

dist_fib :: Int -> Int -> Int -> Par Integer
dist_fib seqThreshold parThreshold n
  | n <= k    = force $ fib n
  | n <= l    = par_fib seqThreshold n
  | otherwise = do v <- new
                   gv <- glob v
                   let val = dist_fib seqThreshold parThreshold (n - 1) >>=
                             force >>=
                             rput gv . toClosure
                   let env = encodeEnv (seqThreshold, parThreshold, n, gv)
                   let fun = dist_fib_Static
                   spark $ unsafeMkClosure val fun env
                   y <- dist_fib seqThreshold parThreshold (n - 2)
                   clo_x <- get v
                   force $ unClosure clo_x + y
  where k = max 1 seqThreshold
        l = parThreshold

dist_fib_Static :: Static (Env -> Par ())
dist_fib_Static = staticAs
  (\ env -> let (seqThreshold, parThreshold, n, gv) = decodeEnv env
              in dist_fib seqThreshold parThreshold (n - 1) >>=
                 force >>=
                 rput gv . toClosure)
  "Main.dist_fib_Static"


-----------------------------------------------------------------------------
-- initialisation, argument processing and 'main'

-- initialize random number generator
initrand :: Int -> IO ()
initrand seed = do
  when (seed /= 0) $ do
    ranks <- MPI.allRanks
    self <- MPI.myRank
    let i = fromJust $ elemIndex self ranks
    setStdGen (mkStdGen (seed + i))


-- parse runtime system config options (+ seed for random number generator)
parseOpts :: [String] -> (RTSConf, Int, [String])
parseOpts args = go (defaultRTSConf, 0, args) where
  go :: (RTSConf, Int, [String]) -> (RTSConf, Int, [String])
  go (conf, seed, [])   = (conf, seed, [])
  go (conf, seed, s:ss) =
   case stripPrefix "-rand=" s of
   Just s  -> go (conf, read s, ss)
   Nothing ->
    case stripPrefix "-d" s of
    Just s  -> go (conf { debugLvl = read s }, seed, ss)
    Nothing ->
     case stripPrefix "-scheds=" s of
     Just s  -> go (conf { scheds = read s }, seed, ss)
     Nothing ->
      case stripPrefix "-wakeup=" s of
      Just s  -> go (conf { wakeupDly = read s }, seed, ss)
      Nothing ->
       case stripPrefix "-hops=" s of
       Just s  -> go (conf { maxHops = read s }, seed, ss)
       Nothing ->
        case stripPrefix "-maxFish=" s of
        Just s  -> go (conf { maxFish = read s }, seed, ss)
        Nothing ->
         case stripPrefix "-minSched=" s of
         Just s  -> go (conf { minSched = read s }, seed, ss)
         Nothing ->
          case stripPrefix "-minNoWork=" s of
          Just s  -> go (conf { minFishDly = read s }, seed, ss)
          Nothing ->
           case stripPrefix "-maxNoWork=" s of
           Just s  -> go (conf { maxFishDly = read s }, seed, ss)
           Nothing ->
            (conf, seed, s:ss)


-- parse (optional) arguments in this order: 
-- * version to run
-- * argument to Fibonacci function
-- * threshold below which to execute sequentially
-- * threshold below which to use shared-memory parallelism
parseArgs :: [String] -> (Int, Int, Int, Int)
parseArgs []     = (defVers, defN, defSeqThreshold, defParThreshold)
parseArgs (s:ss) =
  let go :: Int -> [String] -> (Int, Int, Int, Int)
      go v []           = (v, defN,    defSeqThreshold, defParThreshold)
      go v [s1]         = (v, read s1, defSeqThreshold, defParThreshold)
      go v [s1,s2]      = (v, read s1, read s2,         read s2)
      go v (s1:s2:s3:_) = (v, read s1, read s2,         read s3)
  in case stripPrefix "v" s of
       Just s' -> go (read s') ss
       Nothing -> go defVers (s:ss)

-- defaults for optional arguments
defVers         =  2 :: Int  -- version
defN            = 40 :: Int  -- Fibonacci argument
defParThreshold = 30 :: Int  -- shared-memory threshold
defSeqThreshold = 30 :: Int  -- sequential threshold


main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  registerStatic
  MPI.defaultWithMPI $ do
    opts_args <- getArgs
    let (conf, seed, args) = parseOpts opts_args
    let (version, n, seqThreshold, parThreshold) = parseArgs args
    initrand seed
    case version of
      0 -> do (x, t) <- timeIO $ evaluate
                          (fib n)
              putStrLn $
                "{v0} fib " ++ show n ++ " = " ++ show x ++
                " {runtime=" ++ show t ++ "}"
      1 -> do (output, t) <- timeIO $ evaluate =<< runParIO conf
                               (par_fib seqThreshold n)
              case output of
                Just x  -> putStrLn $
                             "{v1, " ++ 
                             "seqThreshold=" ++ show seqThreshold ++ "} " ++
                             "fib " ++ show n ++ " = " ++ show x ++
                             " {runtime=" ++ show t ++ "}"
                Nothing -> return ()
      2 -> do (output, t) <- timeIO $ evaluate =<< runParIO conf
                               (dist_fib seqThreshold parThreshold n)
              case output of
                Just x  -> putStrLn $
                             "{v2, " ++
                             "seqThreshold=" ++ show seqThreshold ++ ", " ++
                             "parThreshold=" ++ show parThreshold ++ "} " ++
                             "fib " ++ show n ++ " = " ++ show x ++
                             " {runtime=" ++ show t ++ "}"
                Nothing -> return ()
      _ -> return ()