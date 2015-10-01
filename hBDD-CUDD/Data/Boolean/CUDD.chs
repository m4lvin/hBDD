-- -*- haskell -*-- -----------------------------------------------
-- |
-- Module      :  Data.Boolean.CUDD
-- Copyright   :  (C) 2002-2005, 2009 University of New South Wales, (C) 2009-2011 Peter Gammie
-- License     :  LGPL (see COPYING.LIB for details)
--
-- A binding for CUDD (Fabio Somenzi, University of Colorado).
--
-- Note this library is not thread-safe.
-------------------------------------------------------------------
module Data.Boolean.CUDD
    (
        BDD
    ,	module Data.Boolean

        -- * CUDD-specific functions
--          ,	gc
    ,	stats
    ,	reorder
    ,	dynamicReordering
    ,	varIndices
    ,	bddSize
    ,	printInfo
    ) where

-------------------------------------------------------------------
-- Dependencies.
-------------------------------------------------------------------

#include "cudd_im.h"

import Control.DeepSeq  ( NFData, rnf )
import Control.Monad	( foldM, liftM, mapAndUnzipM, zipWithM_ )

import Data.IORef	( IORef, newIORef, readIORef, writeIORef )
import Data.List	( genericLength )
import Data.Maybe	( fromJust, isJust )

import Data.Map         ( Map )
import qualified Data.Map as Map

import Foreign		( ForeignPtr, withForeignPtr, newForeignPtr, newForeignPtr_, finalizerFree, touchForeignPtr
                        , Ptr, advancePtr, castPtr, peek, pokeElemOff, ptrToIntPtr
                        , mallocArray )
import Foreign.C

import GHC.ForeignPtr   ( newConcForeignPtr )

import System.IO	( Handle, hIsReadable, hIsWritable )
-- import System.Mem	( performGC )
import System.Posix.IO	( handleToFd )
import System.IO.Unsafe	( unsafePerformIO )

import Data.Boolean

-------------------------------------------------------------------
-- Extra FFI functions.
-------------------------------------------------------------------

-- | A C file handle.
{#pointer *FILE -> CFile#}

-- | Convert a Haskell Handle into a C FILE *.
-- - FIXME: throw exception on error.
-- - suggested by Simon Marlow.
handleToCFile :: Handle -> IO FILE
handleToCFile h =
    do r <- hIsReadable h
       w <- hIsWritable h
       modestr <- newCString $ mode r w
       fd <- handleToFd h
       {#call unsafe fdopen#} (cToNum fd) modestr
    where mode :: Bool -> Bool -> String
          mode False False = error "Handle not readable or writable!"
          mode False True  = "w"
          mode True  False = "r"
          mode True  True  = "r+" -- FIXME

-- | The Haskell Handle is unusable after calling 'handleToCFile',
-- so provide a neutered "fprintf"-style thing here.
printCFile :: FILE -> String -> IO ()
printCFile file str =
    withCString str ({#call unsafe fprintf_neutered#} file)

--  Close a C FILE *.
-- - FIXME: throw exception on error.
-- closeCFile :: FILE -> IO ()
-- closeCFile cfile = do {#call unsafe fclose#} cfile
--                    return ()

cToNum :: (Num i, Integral e) => e -> i
cToNum  = fromIntegral . toInteger
{-# INLINE cToNum #-}

cFromEnum :: (Integral i, Enum e) => e -> i
cFromEnum  = fromIntegral . fromEnum
{-# INLINE cFromEnum #-}

-------------------------------------------------------------------
-- Types.
-------------------------------------------------------------------

-- | The BDD manager, which we hide from clients.
{#pointer *DdManager as DDManager newtype#}

-- | The arguments to 'Cudd_Init'.
{#enum CuddSubtableSize {} #}
{#enum CuddCacheSize {} #}

-- | Variable reordering tree options.
{#enum CuddMTRParams {} #}

-- | The abstract type of BDDs.
{#pointer *DdNode as BDD foreign newtype#}

{-# INLINE withBDD #-}

-- BDDs are just pointers, so there's no work to do when we @deepseq@ them.
instance Control.DeepSeq.NFData BDD where
  rnf x = seq x ()

-- Belt-and-suspenders equality checking and ordering.
instance Eq BDD where
    bdd0 == bdd1 = unsafePerformIO $
      withBDD bdd0 $ \bdd0p -> withBDD bdd1 $ \bdd1p ->
        return $ bdd0p == bdd1p

instance Ord BDD where
    bdd0 <= bdd1 = unsafePerformIO $
      withBDD bdd0 $ \bdd0p -> withBDD bdd1 $ \bdd1p ->
        return $ bdd0p == bdd1p || bdd0p < bdd1p

instance Show BDD where
-- Print out the BDD as a sum-of-products.
    showsPrec _ = sop

-------------------------------------------------------------------
-- Administrative functions.
-------------------------------------------------------------------

-- | The BDD manager. This needs to be invoked before any of the
-- following functions... which we arrange for automagically.
ddmanager :: DDManager
ddmanager = unsafePerformIO $
  {#call unsafe Cudd_Init as _cudd_Init #}
    0 0 (cFromEnum UNIQUE_SLOTS) (cFromEnum CACHE_SLOTS) 0
{-# NOINLINE ddmanager #-}

-- | A map to and from BDD variable numbers.
-- FIXME: the second one would be more efficiently Data.IntMap, but we don't use it often.
type VarMap = (Map String BDD, Map CUInt String)

-- | Tracks existing variables.
bdd_vars :: IORef VarMap
bdd_vars = unsafePerformIO $ newIORef (Map.empty, Map.empty)
{-# NOINLINE bdd_vars #-}

-- | Attaches a finalizer to a BDD object.
-- The call to "Cudd_Ref" happens in C to ensure atomicity.
-- Returning objects with initial refcount 0 is a bad design decision.
addBDDfinalizer :: Ptr BDD -> IO BDD
addBDDfinalizer bddp = liftM BDD $ newConcForeignPtr bddp bddf
    where bddf = {#call unsafe Cudd_RecursiveDeref as _cudd_RecursiveDeref#} ddmanager bddp
                   >> return ()
{-# INLINE addBDDfinalizer #-}

-- | Attaches a null finalizer to a 'BDD' object.
-- Used for variables and constants.
addBDDnullFinalizer :: Ptr BDD -> IO BDD
addBDDnullFinalizer bddp = fmap BDD $ newForeignPtr_ bddp
{-# INLINE addBDDnullFinalizer #-}

-- Simulate an "apply" function to simplify atomic refcount incrementing.
{#enum CuddBinOp {} #}

-------------------------------------------------------------------
-- Logical operations.
-------------------------------------------------------------------

-- | Allocate a variable.
newVar :: IO (Ptr BDD) -> String -> IO (Maybe CUInt, BDD)
newVar allocVar label =
      do (toBDD, fromBDD) <- readIORef bdd_vars
         case label `Map.lookup` toBDD of
           Just bdd -> return (Nothing, bdd)
           Nothing ->
             do bddp <- allocVar
                vid <- fmap cToNum $
                         {#call unsafe Cudd_NodeReadIndex as _cudd_NodeReadIndex#} bddp
                --putStrLn $ label ++ " -> " ++ (show (vid, bdd))
                bdd <- addBDDnullFinalizer bddp
                writeIORef bdd_vars ( Map.insert label bdd   toBDD
                                    , Map.insert vid   label fromBDD )
                return (Just vid, bdd)

instance BooleanVariable BDD where
    bvar label = unsafePerformIO $
      fmap snd $ newVar ({#call unsafe Cudd_bddNewVar as _cudd_bddNewVar#} ddmanager)  label

    bvars labels =
      case labels of
        [] -> []
        ls -> unsafePerformIO $
          do (vids, vars) <- mapAndUnzipM (newVar ({#call unsafe Cudd_bddNewVar as _cudd_bddNewVar#} ddmanager)) ls
             if all isJust vids
               then groupVars (fromJust (head vids)) (genericLength vids)
               else putStrLn $ "hBDD-CUDD warning: not grouping variables " ++ show ls
             return vars
      where
        -- FIXME why one or the other?
        groupVars vid len = makeTreeNode ddmanager vid len (cFromEnum CUDD_MTR_DEFAULT) >> return ()
        -- groupVars vid len = makeTreeNode ddmanager vid len (cFromEnum CUDD_MTR_FIXED) >> return ()
        makeTreeNode = {#call unsafe Cudd_MakeTreeNode as _cudd_MakeTreeNode#}

    unbvar bdd = unsafePerformIO $ bdd `seq`
                   withBDD bdd $ \bddp ->
                     do vid <- {#call unsafe Cudd_NodeReadIndex as _cudd_NodeReadIndex#} bddp
                        (_, fromBDD) <- readIORef bdd_vars
                        return $ case cToNum vid `Map.lookup` fromBDD of
                                   Nothing -> "(VID: " ++ show vid ++ ")"
                                   Just v  -> v

instance Boolean BDD where
    true  = cudd_constant {#call unsafe Cudd_ReadOne as _cudd_ReadOne#}
    false = cudd_constant {#call unsafe Cudd_ReadLogicZero as _cudd_ReadLogicZero#}

    (/\)  = bddBinOp AND
    neg x = unsafePerformIO $ withBDD x $ \xp ->
      {#call unsafe cudd_bddNot#} xp >>= addBDDfinalizer

    nand  = bddBinOp NAND
    (\/)  = bddBinOp OR
    nor   = bddBinOp NOR
    xor   = bddBinOp XOR
    -- (-->) = FIXME ???
    (<->) = bddBinOp XNOR

    ifthenelse i t e = unsafePerformIO $
      withBDD i $ \ip -> withBDD t $ \tp -> withBDD e $ \ep ->
        {#call unsafe cudd_bddIte#} ddmanager ip tp ep
          >>= addBDDfinalizer

cudd_constant :: (DDManager -> IO (Ptr BDD)) -> BDD
cudd_constant f = unsafePerformIO $ f ddmanager >>= addBDDnullFinalizer
{-# INLINE cudd_constant #-}

bddBinOp :: CuddBinOp -> BDD -> BDD -> BDD
bddBinOp op x y = unsafePerformIO $
  withBDD x $ \xp -> withBDD y $ \yp ->
    {#call unsafe cudd_BinOp#} ddmanager (cFromEnum op) xp yp >>= addBDDfinalizer
{-# INLINE bddBinOp #-}

instance QBF BDD where
    data Group BDD = MkGroup !BDD

    mkGroup = MkGroup . conjoin -- FIXME maybe use Cudd_bddComputeCube
    exists = cudd_exists
    forall = cudd_forall
    rel_product = cudd_rel_product

instance Substitution BDD where
  -- Cache substitution arrays.
  data Subst BDD = MkSubst {-# UNPACK #-} !Int
                           {-# UNPACK #-} !(ForeignPtr (Ptr BDD))
                           {-# UNPACK #-} !(ForeignPtr (Ptr BDD))

  mkSubst = cudd_mkSubst
  rename = cudd_rename
  substitute = error "CUDD substitute" -- cudd_substitute

cudd_mkSubst :: [(BDD, BDD)] -> Subst BDD
cudd_mkSubst subst = unsafePerformIO $
    do arrayx  <- mallocArray len
       arrayx' <- mallocArray len
       zipWithM_ (pokeSubst arrayx arrayx') subst [0..]
       fpx  <- newForeignPtr finalizerFree arrayx
       fpx' <- newForeignPtr finalizerFree arrayx'
       return (MkSubst len fpx fpx')
  where
    pokeSubst :: Ptr (Ptr BDD) -> Ptr (Ptr BDD) -> (BDD, BDD) -> Int -> IO ()
    pokeSubst arrayx arrayx' (v, v') i =
      do withBDD v  $ pokeElemOff arrayx  i
         withBDD v' $ pokeElemOff arrayx' i

    len = length subst
{-# INLINE cudd_mkSubst #-}

instance BDDOps BDD where
    get_bdd_ptr bdd = unsafePerformIO $ withBDD bdd (return . ptrToIntPtr)
    bif bdd = unsafePerformIO $
      do vid <- withBDD bdd {#call unsafe Cudd_NodeReadIndex as _cudd_NodeReadIndex#}
         {#call unsafe Cudd_bddIthVar as _cudd_bddIthVar#} ddmanager (cToNum vid)
           >>= addBDDnullFinalizer
    bthen bdd = unsafePerformIO $
      withBDD bdd $ \bddp ->
        {#call unsafe cudd_bddT#} bddp >>= addBDDfinalizer
    belse bdd = unsafePerformIO $
      withBDD bdd $ \bddp ->
        {#call unsafe cudd_bddE#} bddp >>= addBDDfinalizer

    reduce = cudd_reduce
    satisfy = cudd_satisfy
    support = cudd_support

-------------------------------------------------------------------
-- Implementations.
-------------------------------------------------------------------

withGroup :: Group BDD -> (Ptr BDD -> IO a) -> IO a
withGroup (MkGroup g) = withBDD g

cudd_exists :: Group BDD -> BDD -> BDD
cudd_exists group bdd = unsafePerformIO $ bdd `seq`
  withGroup group $ \groupp -> withBDD bdd $ \bddp ->
    {#call unsafe cudd_bddExistAbstract#} ddmanager bddp groupp
      >>= addBDDfinalizer
{-# INLINE cudd_exists #-}

cudd_forall :: Group BDD -> BDD -> BDD
cudd_forall group bdd = unsafePerformIO $ bdd `seq`
  withGroup group $ \groupp -> withBDD bdd $ \bddp ->
    {#call unsafe cudd_bddUnivAbstract#} ddmanager bddp groupp
      >>= addBDDfinalizer
{-# INLINE cudd_forall #-}

cudd_rel_product :: Group BDD -> BDD -> BDD -> BDD
cudd_rel_product group f g = unsafePerformIO $
  withGroup group $ \groupp -> withBDD f $ \fp -> withBDD g $ \gp ->
    {#call unsafe cudd_bddAndAbstract#} ddmanager fp gp groupp
      >>= addBDDfinalizer
{-# INLINE cudd_rel_product #-}

-- | This function swaps variables, as it uses
-- @cudd_bddSwapVariables@. This is not exactly a "rename" behaviour.
cudd_rename :: Subst BDD -> BDD -> BDD
cudd_rename s@(MkSubst len fpx fpx') f = unsafePerformIO $ s `seq` f `seq`
  withBDD f $ \fp ->
    withForeignPtr fpx $ \arrayx -> withForeignPtr fpx' $ \arrayx' ->
      {#call unsafe cudd_bddSwapVariables#} ddmanager fp arrayx arrayx' (fromIntegral len)
        >>= addBDDfinalizer
{-# INLINE cudd_rename #-}

-- FIXME verify implementation.
cudd_reduce :: BDD -> BDD -> BDD
cudd_reduce f g = unsafePerformIO $
  withBDD f $ \fp -> withBDD g $ \gp ->
    {#call unsafe cudd_bddLICompaction#} ddmanager fp gp
      >>= addBDDfinalizer

-- FIXME verify implementation.
cudd_satisfy :: BDD -> BDD
cudd_satisfy bdd = unsafePerformIO $
  withBDD bdd ({#call unsafe cudd_satone#} ddmanager) >>= addBDDfinalizer

cudd_support :: BDD -> [BDD]
cudd_support bdd = unsafePerformIO $
  do varBitArray <- withBDD bdd ({#call unsafe Cudd_SupportIndex as _cudd_SupportIndex#} ddmanager)
     touchForeignPtr (case bdd of BDD fp -> fp)
     -- The array is as long as the number of variables allocated.
     (_toBDD, fromBDD) <- readIORef bdd_vars
     bdds <- foldM (toBDDs varBitArray) [] (Map.toList fromBDD)
     {#call unsafe cFree#} (castPtr varBitArray)
     return bdds
  where
    toBDDs varBitArray bdds (vid, var) =
      do varInSupport <- peek (advancePtr varBitArray (cToNum vid))
         return $ if varInSupport /= 0
                    then bvar var : bdds
                    else bdds

-------------------------------------------------------------------
-- Operations specific to this BDD binding.
-------------------------------------------------------------------

-- | Dump usage statistics to the given 'Handle'.
stats :: Handle -> IO ()
stats handle =
    do cfile <- handleToCFile handle
       printCFile cfile "CUDD stats\n"
       _ <- {#call unsafe Cudd_PrintInfo as _cudd_PrintInfo#} ddmanager cfile
       printCFile cfile "\nVariable groups\n"
       {#call unsafe cudd_printVarGroups#} ddmanager

----------------------------------------
-- Variable Reordering.
----------------------------------------

{#enum Cudd_ReorderingType as CUDDReorderingMethod {} deriving (Eq, Ord, Show)#}

decodeROM :: ReorderingMethod -> CInt
decodeROM rom = cFromEnum $ case rom of
  ReorderNone -> CUDD_REORDER_NONE
  ReorderSift -> CUDD_REORDER_SIFT
  ReorderSiftSym -> CUDD_REORDER_SYMM_SIFT
  ReorderStableWindow3 -> CUDD_REORDER_WINDOW3

-- | Reorder the variables now.
reorder :: ReorderingMethod -> IO ()
reorder rom = {#call unsafe Cudd_ReduceHeap as _cudd_ReduceHeap#} ddmanager (decodeROM rom) 1 >> return ()

-- | Set the dynamic variable ordering heuristic.
dynamicReordering :: ReorderingMethod -> IO ()
dynamicReordering rom = {#call unsafe Cudd_AutodynEnable as _cudd_AutodynEnable#} ddmanager (decodeROM rom) >> return ()

----------------------------------------
-- | Returns the relationship between BDD indices, BDD ids and
-- variable names. This may be useful for discovering what the
-- dynamic reordering is doing.
--
-- The intention of this function is to return
--   @[(position in variable order, immutable variable id, label)]@
-- so that the variable order can be saved.
----------------------------------------

varIndices :: IO [(CInt, CInt, String)]
varIndices = do (toBDD, _fromBDD) <- readIORef bdd_vars
                mapM procVar $ Map.toList toBDD
    where -- procVar :: (String, BDD) -> IO (CUInt, CUInt, String)
          procVar (var, bdd) =
              do -- FIXME CUDD inconsistently uses signed and unsigned ints.
                 vid <- fmap cToNum $
                          withBDD bdd {#call unsafe Cudd_NodeReadIndex as _cudd_NodeReadIndex#}
                 level <- {#call unsafe Cudd_ReadPerm as _cudd_ReadPerm#} ddmanager vid
                 return (level, vid, var)
{-# NOINLINE varIndices #-}

----------------------------------------
-- BDD Statistics.
----------------------------------------

-- | Determine the size of a BDD.
bddSize :: BDD -> Int
bddSize bdd = unsafePerformIO $
  do size <- withBDD bdd ({#call unsafe Cudd_DagSize as _cudd_DagSize#})
     return $ cToNum size

printInfo :: IO ()
printInfo = {#call unsafe print_stats#} ddmanager
