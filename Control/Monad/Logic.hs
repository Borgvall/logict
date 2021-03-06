{-# LANGUAGE UndecidableInstances, Rank2Types, FlexibleInstances, MultiParamTypeClasses #-}

-------------------------------------------------------------------------
-- |
-- Module      : Control.Monad.Logic
-- Copyright   : (c) Dan Doel
-- License     : BSD3
--
-- Maintainer  : dan.doel@gmail.com
-- Stability   : experimental
-- Portability : non-portable (multi-parameter type classes)
--
-- A backtracking, logic programming monad.
--
--    Adapted from the paper
--    /Backtracking, Interleaving, and Terminating
--        Monad Transformers/, by
--    Oleg Kiselyov, Chung-chieh Shan, Daniel P. Friedman, Amr Sabry
--    (<http://www.cs.rutgers.edu/~ccshan/logicprog/LogicT-icfp2005.pdf>).
-------------------------------------------------------------------------

module Control.Monad.Logic (
    module Control.Monad.Logic.Class,
    -- * The Logic monad
    Logic,
    logic,
    runLogic,
    liftLogic,
    check,
    observe,
    observeMany,
    observeAll,
    -- * The LogicT monad transformer
    LogicT(..),
    runLogicT,
    checkT,
    observeT,
    observeManyT,
    observeAllT,
    -- ** Special constructors for logic computations
    member,
    iterates,
    iterates2,
    module Control.Monad,
    module Control.Monad.Trans
  ) where

import Control.Applicative

import Control.Monad
import Control.Monad.Identity
import Control.Monad.Trans

import Control.Monad.Reader.Class
import Control.Monad.State.Class
import Control.Monad.Error.Class

import Data.Monoid (Monoid(mappend, mempty))
import qualified Data.Foldable as F
import qualified Data.Traversable as T

import Control.Monad.Logic.Class

-------------------------------------------------------------------------
-- | A monad transformer for performing backtracking computations
-- layered over another monad 'm'
newtype LogicT m a =
    LogicT { unLogicT :: forall r. (a -> m r -> m r) -> m r -> m r }

-------------------------------------------------------------------------
-- | Check if a solution exist.
--
-- Returns 'True', on the first success. Returns 'False', when the predicate
-- fails.
--
-- Properties:
--
-- > checkT mzero = return False
-- > checkT (return _ `mplus` _) = return True
--
-- One can think about it as an inverse of 'guard':
--
-- > checkT . guard = return
checkT :: Monad m => LogicT m a -> m Bool
checkT m = unLogicT m (\_ _ -> return True) (return False)

-------------------------------------------------------------------------
-- | Extracts the first result from a LogicT computation,
-- failing otherwise.
observeT :: Monad m => LogicT m a -> m a
observeT lt = unLogicT lt (const . return) (fail "No answer.")

-------------------------------------------------------------------------
-- | Extracts all results from a LogicT computation.
observeAllT :: Monad m => LogicT m a -> m [a]
observeAllT m = unLogicT m (liftM . (:)) (return [])

-------------------------------------------------------------------------
-- | Extracts up to a given number of results from a LogicT computation.
observeManyT :: Monad m => Int -> LogicT m a -> m [a]
observeManyT n m
    | n <= 0 = return []
    | n == 1 = unLogicT m (\a _ -> return [a]) (return [])
    | otherwise = unLogicT (msplit m) sk (return [])
 where
 sk Nothing _ = return []
 sk (Just (a, m')) _ = (a:) `liftM` observeManyT (n-1) m'

-------------------------------------------------------------------------
-- | Runs a LogicT computation with the specified initial success and
-- failure continuations.
runLogicT :: LogicT m a -> (a -> m r -> m r) -> m r -> m r
runLogicT = unLogicT

-------------------------------------------------------------------------
-- | Succeed for all members.
--
-- Create the logic computation that succeeds for all members in the
-- supplied 'Foldable' structure.
member :: Foldable t => t a -> LogicT m a
member xs = LogicT $ \sk fk -> F.foldr sk fk xs

-------------------------------------------------------------------------
-- | All results of the function applied an arbitrary number of times to
-- the start value.
--
-- > iterates f x = pure x <|> pure (f x) <|> pure (f (f x)) <|> ...
iterates :: (a -> a) -> a -> LogicT m a
iterates f x0 = LogicT $
  \sk _ -> let iter x = sk x (iter (f x)) in iter x0

-------------------------------------------------------------------------
-- | The two starting values, followed the function applied to the two
-- previous values.
--
-- > iterates2 f x y =
-- >	pure x <|> pure y
-- >	  <|> pure (f x y) <|> pure (f y (f x y)) <|> ...
--
-- For instance the fibonacci numbers can be described as:
--
-- > fibonacci = iterates2 (+) 1 1
iterates2 :: (a -> a -> a) -> a -> a -> LogicT m a
iterates2 f x0 x1 = LogicT $
  \sk _ -> let iter2 x y = sk x (iter2 y (f x y)) in iter2 x0 x1

-------------------------------------------------------------------------
-- | The basic Logic monad, for performing backtracking computations
-- returning values of type 'a'
type Logic = LogicT Identity

-------------------------------------------------------------------------
-- | A smart constructor for Logic computations.
logic :: (forall r. (a -> r -> r) -> r -> r) -> Logic a
logic f = LogicT $ \k -> Identity .
                         f (\a -> runIdentity . k a . Identity) .
                         runIdentity

-------------------------------------------------------------------------
-- | Check if a solution exist.
--
-- 'True', on the first success. 'False', when the predicate fails.
--
-- Properties:
--
-- > check mzero = False
-- > check (return _ `mplus` _) = True
--
-- One can think about it as an inverse of 'guard':
--
-- > check . guard = id
check :: Logic a -> Bool
check = runIdentity . checkT

-------------------------------------------------------------------------
-- | Extracts the first result from a Logic computation.
observe :: Logic a -> a
observe = runIdentity . observeT 

-------------------------------------------------------------------------
-- | Extracts all results from a Logic computation.
observeAll :: Logic a -> [a]
observeAll = runIdentity . observeAllT

-------------------------------------------------------------------------
-- | Extracts up to a given number of results from a Logic computation.
observeMany :: Int -> Logic a -> [a]
observeMany i = take i . observeAll
-- Implementing 'observeMany' using 'observeManyT' is quite costly,
-- because it calls 'msplit' multiple times.

-------------------------------------------------------------------------
-- | Runs a Logic computation with the specified initial success and
-- failure continuations.
runLogic :: Logic a -> (a -> r -> r) -> r -> r
runLogic l s f = runIdentity $ unLogicT l si fi
 where
 si = fmap . s
 fi = Identity f

-------------------------------------------------------------------------
-- | Lift a pure logic computation in any context.
liftLogic :: Logic a -> LogicT m a
liftLogic l = LogicT $ runLogic l

instance Functor (LogicT f) where
    fmap f lt = LogicT $ \sk fk -> unLogicT lt (sk . f) fk

instance Applicative (LogicT f) where
    pure a = LogicT $ \sk fk -> sk a fk
    f <*> a = LogicT $ \sk fk -> unLogicT f (\g fk' -> unLogicT a (sk . g) fk') fk

instance Alternative (LogicT f) where
    empty = LogicT $ \_ fk -> fk
    f1 <|> f2 = LogicT $ \sk fk -> unLogicT f1 sk (unLogicT f2 sk fk)

instance Monad (LogicT m) where
    return a = LogicT $ \sk fk -> sk a fk
    m >>= f = LogicT $ \sk fk -> unLogicT m (\a fk' -> unLogicT (f a) sk fk') fk
    fail _ = LogicT $ \_ fk -> fk

instance MonadPlus (LogicT m) where
    mzero = LogicT $ \_ fk -> fk
    m1 `mplus` m2 = LogicT $ \sk fk -> unLogicT m1 sk (unLogicT m2 sk fk)

instance MonadTrans LogicT where
    lift m = LogicT $ \sk fk -> m >>= \a -> sk a fk

instance (MonadIO m) => MonadIO (LogicT m) where
    liftIO = lift . liftIO

instance (Monad m) => MonadLogic (LogicT m) where
    -- 'msplit' is quite costly even if the base 'Monad' is 'Identity'.
    -- Try to avoid it.
    msplit m = lift $ unLogicT m ssk (return Nothing)
     where
     ssk a fk = return $ Just (a, (lift fk >>= reflect))
    once m = LogicT $ \sk fk -> unLogicT m (\a _ -> sk a fk) fk
    lnot m = LogicT $ \sk fk -> unLogicT m (\_ _ -> fk) (sk () fk)

instance (Monad m, F.Foldable m) => F.Foldable (LogicT m) where
    foldMap f m = F.fold $ unLogicT m (liftM . mappend . f) (return mempty)
{-# RULES
"foldr [LogicT Identity]" forall (f::a->b->b) (z::b) (m::Logic a).
  F.foldr f z m = runLogic m f z
 #-}

instance T.Traversable (LogicT Identity) where
    traverse g l = runLogic l (\a ft -> cons <$> g a <*> ft) (pure mzero)
     where cons a l' = return a `mplus` l'

-- Needs undecidable instances
instance MonadReader r m => MonadReader r (LogicT m) where
    ask = lift ask
    local f m = LogicT $ \sk fk -> unLogicT m ((local f .) . sk) (local f fk)

-- Needs undecidable instances
instance MonadState s m => MonadState s (LogicT m) where
    get = lift get
    put = lift . put

-- Needs undecidable instances
instance MonadError e m => MonadError e (LogicT m) where
  throwError = lift . throwError
  catchError m h = LogicT $ \sk fk -> let
      handle r = r `catchError` \e -> unLogicT (h e) sk fk
    in handle $ unLogicT m (\a -> sk a . handle) fk
