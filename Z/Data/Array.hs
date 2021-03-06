{-|
Module      : Z.Data.Array
Description : Fast boxed and unboxed arrays
Copyright   : (c) Dong Han, 2017
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

Unified unboxed and boxed array operations using type family.

All operations are NOT bound checked, if you need checked operations please use "Z.Data.Array.Checked".
It exports exactly same APIs so that you can switch between without pain.

Some mnemonics:

  * 'newArr', 'newArrWith' return mutable array, 'readArr', 'writeArr' works on them, 'setArr' fill elements
     with offset and length.

  * 'indexArr' works on immutable one, use 'indexArr'' to avoid indexing thunk.

  * The order of arguements of 'copyArr', 'copyMutableArr' and 'moveArr' are always target and its offset
    come first, and source and source offset follow, copying length comes last.
-}

module Z.Data.Array (
  -- * Arr typeclass
    Arr(..)
  , RealWorld
  -- * Boxed array type
  , Array(..)
  , MutableArray(..)
  , SmallArray(..)
  , SmallMutableArray(..)
  , uninitialized
  -- * Primitive array type
  , PrimArray(..)
  , MutablePrimArray(..)
  , Prim(..)
  -- * Array operations
  , newPinnedPrimArray, newAlignedPinnedPrimArray
  , copyPrimArrayToPtr, copyMutablePrimArrayToPtr, copyPtrToMutablePrimArray
  , primArrayContents, mutablePrimArrayContents, withPrimArrayContents, withMutablePrimArrayContents
  , isPrimArrayPinned, isMutablePrimArrayPinned
  -- * Unlifted array type
  , UnliftedArray(..)
  , MutableUnliftedArray(..)
  , PrimUnlifted(..)
  -- * The 'ArrayException' type
  , ArrayException(..)
  -- * Cast between primitive arrays
  , Cast
  , castArray
  , castMutableArray
  -- * Re-export
  , sizeOf
  ) where

import           Control.Exception            (ArrayException (..), throw)
import           Control.Monad.Primitive
import           Data.Primitive.Array
import           Data.Primitive.ByteArray
import           Data.Primitive.PrimArray
import           Data.Primitive.Ptr           (copyPtrToMutablePrimArray)
import           Data.Primitive.SmallArray
import           Data.Primitive.Types
import           GHC.Exts
import           Z.Data.Array.Cast
import           Z.Data.Array.UnliftedArray


-- | Bottom value (@throw ('UndefinedElement' 'Data.Array.uninitialized')@)
-- for initialize new boxed array('Array', 'SmallArray'..).
--
uninitialized :: a
uninitialized = throw (UndefinedElement "Data.Array.uninitialized")


-- | A typeclass to unify box & unboxed, mutable & immutable array operations.
--
-- Most of these functions simply wrap their primitive counterpart, if there's no primitive ones,
-- we polyfilled using other operations to get the same semantics.
--
-- One exception is that 'shrinkMutableArr' only perform closure resizing on 'PrimArray' because
-- current RTS support only that, 'shrinkMutableArr' will do nothing on other array type.
--
-- It's reasonable to trust GHC with specializing & inlining these polymorphric functions.
-- They are used across this package and perform identical to their monomophric counterpart.
--
class Arr (arr :: * -> * ) a where


    -- | Mutable version of this array type.
    --
    type MArr arr = (mar :: * -> * -> *) | mar -> arr


    -- | Make a new array with given size.
    --
    -- For boxed array, all elements are 'uninitialized' which shall not be accessed.
    -- For primitive array, elements are just random garbage.
    newArr :: (PrimMonad m, PrimState m ~ s) => Int -> m (MArr arr s a)


    -- | Make a new array and fill it with an initial value.
    newArrWith :: (PrimMonad m, PrimState m ~ s) => Int -> a -> m (MArr arr s a)


    -- | Index mutable array in a primitive monad.
    readArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> m a


    -- | Write mutable array in a primitive monad.
    writeArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> a -> m ()


    -- | Fill mutable array with a given value.
    setArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> Int -> a -> m ()


    -- | Index immutable array, which is a pure operation. This operation often
    -- result in an indexing thunk for lifted arrays, use 'indexArr\'' or 'indexArrM'
    -- if that's not desired.
    indexArr :: arr a -> Int -> a


    -- | Index immutable array, pattern match on the unboxed unit tuple to force
    -- indexing (without forcing the element).
    indexArr' :: arr a -> Int -> (# a #)


    -- | Index immutable array in a primitive monad, this helps in situations that
    -- you want your indexing result is not a thunk referencing whole array.
    indexArrM :: (Monad m) => arr a -> Int -> m a


    -- | Safely freeze mutable array by make a immutable copy of its slice.
    freezeArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> Int -> m (arr a)


    -- | Safely thaw immutable array by make a mutable copy of its slice.
    thawArr :: (PrimMonad m, PrimState m ~ s) => arr a -> Int -> Int -> m (MArr arr s a)


    -- | In place freeze a mutable array, the original mutable array can not be used
    -- anymore.
    unsafeFreezeArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> m (arr a)


    -- | In place thaw a immutable array, the original immutable array can not be used
    -- anymore.
    unsafeThawArr :: (PrimMonad m, PrimState m ~ s) => arr a -> m (MArr arr s a)


    -- | Copy a slice of immutable array to mutable array at given offset.
    copyArr ::  (PrimMonad m, PrimState m ~ s)
            => MArr arr s a -- ^ target
            -> Int          -- ^ target offset
            -> arr a        -- ^ source
            -> Int          -- ^ source offset
            -> Int          -- ^ source length
            -> m ()


    -- | Copy a slice of mutable array to mutable array at given offset.
    -- The two mutable arrays shall no be the same one.
    copyMutableArr :: (PrimMonad m, PrimState m ~ s)
                   => MArr arr s a  -- ^ target
                   -> Int           -- ^ target offset
                   -> MArr arr s a  -- ^ source
                   -> Int           -- ^ source offset
                   -> Int           -- ^ source length
                   -> m ()


    -- | Copy a slice of mutable array to mutable array at given offset.
    -- The two mutable arrays may be the same one.
    moveArr :: (PrimMonad m, PrimState m ~ s)
            => MArr arr s a  -- ^ target
            -> Int           -- ^ target offset
            -> MArr arr s a  -- ^ source
            -> Int           -- ^ source offset
            -> Int           -- ^ source length
            -> m ()


    -- | Create immutable copy.
    cloneArr :: arr a -> Int -> Int -> arr a


    -- | Create mutable copy.
    cloneMutableArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> Int -> m (MArr arr s a)


    -- | Resize mutable array to given size.
    resizeMutableArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> m (MArr arr s a)


    -- | Shrink mutable array to given size. This operation only works on primitive arrays.
    -- For some array types, this is a no-op, e.g. 'sizeOfMutableArr' will not change.
    shrinkMutableArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> Int -> m ()


    -- | Is two mutable array are reference equal.
    sameMutableArr :: MArr arr s a -> MArr arr s a -> Bool


    -- | Size of immutable array.
    sizeofArr :: arr a -> Int


    -- | Size of mutable array.
    sizeofMutableArr :: (PrimMonad m, PrimState m ~ s) => MArr arr s a -> m Int


    -- | Is two immutable array are referencing the same one.
    --
    -- Note that 'sameArr' 's result may change depending on compiler's optimizations, for example
    -- @let arr = runST ... in arr `sameArr` arr@ may return false if compiler decides to
    -- inline it.
    --
    -- See https://ghc.haskell.org/trac/ghc/ticket/13908 for more background.
    --
    sameArr :: arr a -> arr a -> Bool

instance Arr Array a where
    type MArr Array = MutableArray
    newArr n = newArray n uninitialized
    {-# INLINE newArr #-}
    newArrWith = newArray
    {-# INLINE newArrWith #-}
    readArr = readArray
    {-# INLINE readArr #-}
    writeArr = writeArray
    {-# INLINE writeArr #-}
    setArr marr s l x = go s
      where
        !sl = s + l
        go !i | i >= sl = return ()
              | otherwise = writeArray marr i x >> go (i+1)
    {-# INLINE setArr #-}
    indexArr = indexArray
    {-# INLINE indexArr #-}
    indexArr' (Array arr#) (I# i#) = indexArray# arr# i#
    {-# INLINE indexArr' #-}
    indexArrM = indexArrayM
    {-# INLINE indexArrM #-}
    freezeArr = freezeArray
    {-# INLINE freezeArr #-}
    thawArr = thawArray
    {-# INLINE thawArr #-}
    unsafeFreezeArr = unsafeFreezeArray
    {-# INLINE unsafeFreezeArr #-}
    unsafeThawArr = unsafeThawArray
    {-# INLINE unsafeThawArr #-}

    copyArr = copyArray
    {-# INLINE copyArr #-}
    copyMutableArr = copyMutableArray
    {-# INLINE copyMutableArr #-}

    moveArr marr1 s1 marr2 s2 l
        | l <= 0 = return ()
        | sameMutableArray marr1 marr2 =
            case compare s1 s2 of
                LT ->
                    let !d = s2 - s1
                        !s2l = s2 + l
                        go !i | i >= s2l = return ()
                              | otherwise = do x <- readArray marr2 i
                                               writeArray marr1 (i-d) x
                                               go (i+1)
                    in go s2

                EQ -> return ()

                GT ->
                    let !d = s1 - s2
                        go !i | i < s2 = return ()
                              | otherwise = do x <- readArray marr2 i
                                               writeArray marr1 (i+d) x
                                               go (i-1)
                    in go (s2+l-1)
        | otherwise = copyMutableArray marr1 s1 marr2 s2 l
    {-# INLINE moveArr #-}

    cloneArr = cloneArray
    {-# INLINE cloneArr #-}
    cloneMutableArr = cloneMutableArray
    {-# INLINE cloneMutableArr #-}

    resizeMutableArr marr n = do
        marr' <- newArray n uninitialized
        copyMutableArray marr' 0 marr 0 (sizeofMutableArray marr)
        return marr'
    {-# INLINE resizeMutableArr #-}
    shrinkMutableArr _ _ = return ()
    {-# INLINE shrinkMutableArr #-}

    sameMutableArr = sameMutableArray
    {-# INLINE sameMutableArr #-}
    sizeofArr = sizeofArray
    {-# INLINE sizeofArr #-}
    sizeofMutableArr = return . sizeofMutableArray
    {-# INLINE sizeofMutableArr #-}

    sameArr (Array arr1#) (Array arr2#) = isTrue# (
        sameMutableArray# (unsafeCoerce# arr1#) (unsafeCoerce# arr2#))
    {-# INLINE sameArr #-}

instance Arr SmallArray a where
    type MArr SmallArray = SmallMutableArray
    newArr n = newSmallArray n uninitialized
    {-# INLINE newArr #-}
    newArrWith = newSmallArray
    {-# INLINE newArrWith #-}
    readArr = readSmallArray
    {-# INLINE readArr #-}
    writeArr = writeSmallArray
    {-# INLINE writeArr #-}
    setArr marr s l x = go s
      where
        !sl = s + l
        go !i | i >= sl = return ()
              | otherwise = writeSmallArray marr i x >> go (i+1)
    {-# INLINE setArr #-}
    indexArr = indexSmallArray
    {-# INLINE indexArr #-}
    indexArr' (SmallArray arr#) (I# i#) = indexSmallArray# arr# i#
    {-# INLINE indexArr' #-}
    indexArrM = indexSmallArrayM
    {-# INLINE indexArrM #-}
    freezeArr = freezeSmallArray
    {-# INLINE freezeArr #-}
    thawArr = thawSmallArray
    {-# INLINE thawArr #-}
    unsafeFreezeArr = unsafeFreezeSmallArray
    {-# INLINE unsafeFreezeArr #-}
    unsafeThawArr = unsafeThawSmallArray
    {-# INLINE unsafeThawArr #-}

    copyArr = copySmallArray
    {-# INLINE copyArr #-}
    copyMutableArr = copySmallMutableArray
    {-# INLINE copyMutableArr #-}

    moveArr marr1 s1 marr2 s2 l
        | l <= 0 = return ()
        | sameMutableArr marr1 marr2 =
            case compare s1 s2 of
                LT ->
                    let !d = s2 - s1
                        !s2l = s2 + l
                        go !i | i >= s2l = return ()
                              | otherwise = do x <- readSmallArray marr2 i
                                               writeSmallArray marr1 (i-d) x
                                               go (i+1)
                    in go s2

                EQ -> return ()

                GT ->
                    let !d = s1 - s2
                        go !i | i < s2 = return ()
                              | otherwise = do x <- readSmallArray marr2 i
                                               writeSmallArray marr1 (i+d) x
                                               go (i-1)
                    in go (s2+l-1)
        | otherwise = copySmallMutableArray marr1 s1 marr2 s2 l
    {-# INLINE moveArr #-}

    cloneArr = cloneSmallArray
    {-# INLINE cloneArr #-}
    cloneMutableArr = cloneSmallMutableArray
    {-# INLINE cloneMutableArr #-}

    resizeMutableArr marr n = do
        marr' <- newSmallArray n uninitialized
        copySmallMutableArray marr' 0 marr 0 (sizeofSmallMutableArray marr)
        return marr'
    {-# INLINE resizeMutableArr #-}
#if MIN_VERSION_base(4,14,0)
    shrinkMutableArr = shrinkSmallMutableArray
#else
    shrinkMutableArr _ _ = return ()
#endif
    {-# INLINE shrinkMutableArr #-}

    sameMutableArr (SmallMutableArray smarr1#) (SmallMutableArray smarr2#) =
        isTrue# (sameSmallMutableArray# smarr1# smarr2#)
    {-# INLINE sameMutableArr #-}
    sizeofArr = sizeofSmallArray
    {-# INLINE sizeofArr #-}
    sizeofMutableArr = return . sizeofSmallMutableArray
    {-# INLINE sizeofMutableArr #-}

    sameArr (SmallArray arr1#) (SmallArray arr2#) = isTrue# (
        sameSmallMutableArray# (unsafeCoerce# arr1#) (unsafeCoerce# arr2#))
    {-# INLINE sameArr #-}

instance Prim a => Arr PrimArray a where
    type MArr PrimArray = MutablePrimArray
    newArr = newPrimArray
    {-# INLINE newArr #-}
    newArrWith n x = do
        marr <- newPrimArray n
        setPrimArray marr 0 n x
        return marr
    {-# INLINE newArrWith #-}
    readArr = readPrimArray
    {-# INLINE readArr #-}
    writeArr = writePrimArray
    {-# INLINE writeArr #-}
    setArr = setPrimArray
    {-# INLINE setArr #-}
    indexArr = indexPrimArray
    {-# INLINE indexArr #-}
    indexArr' arr i = (# indexPrimArray arr i #)
    {-# INLINE indexArr' #-}
    indexArrM arr i = return (indexPrimArray arr i)
    {-# INLINE indexArrM #-}
    freezeArr = freezePrimArray
    {-# INLINE freezeArr #-}
    thawArr arr s l = do
        marr' <- newPrimArray l
        copyPrimArray marr' 0 arr s l
        return marr'
    {-# INLINE thawArr #-}
    unsafeFreezeArr = unsafeFreezePrimArray
    {-# INLINE unsafeFreezeArr #-}
    unsafeThawArr = unsafeThawPrimArray
    {-# INLINE unsafeThawArr #-}

    copyArr = copyPrimArray
    {-# INLINE copyArr #-}
    copyMutableArr = copyMutablePrimArray
    {-# INLINE copyMutableArr #-}

    moveArr (MutablePrimArray dst) doff (MutablePrimArray src) soff n =
        moveByteArray (MutableByteArray dst) (doff*siz) (MutableByteArray src) (soff*siz) (n*siz)
      where siz = sizeOf (undefined :: a)
    {-# INLINE moveArr #-}

    cloneArr = clonePrimArray
    {-# INLINE cloneArr #-}
    cloneMutableArr = cloneMutablePrimArray
    {-# INLINE cloneMutableArr #-}

    resizeMutableArr = resizeMutablePrimArray
    {-# INLINE resizeMutableArr #-}
    shrinkMutableArr = shrinkMutablePrimArray
    {-# INLINE shrinkMutableArr #-}

    sameMutableArr = sameMutablePrimArray
    {-# INLINE sameMutableArr #-}
    sizeofArr = sizeofPrimArray
    {-# INLINE sizeofArr #-}
    sizeofMutableArr = getSizeofMutablePrimArray
    {-# INLINE sizeofMutableArr #-}

    sameArr (PrimArray ba1#) (PrimArray ba2#) =
        isTrue# (sameMutableByteArray# (unsafeCoerce# ba1#) (unsafeCoerce# ba2#))
    {-# INLINE sameArr #-}

instance PrimUnlifted a => Arr UnliftedArray a where
    type MArr UnliftedArray = MutableUnliftedArray
    newArr = unsafeNewUnliftedArray
    {-# INLINE newArr #-}
    newArrWith = newUnliftedArray
    {-# INLINE newArrWith #-}
    readArr = readUnliftedArray
    {-# INLINE readArr #-}
    writeArr = writeUnliftedArray
    {-# INLINE writeArr #-}
    setArr = setUnliftedArray
    {-# INLINE setArr #-}
    indexArr = indexUnliftedArray
    {-# INLINE indexArr #-}
    indexArr' arr i = (# indexUnliftedArray arr i #)
    {-# INLINE indexArr' #-}
    indexArrM arr i = return (indexUnliftedArray arr i)
    {-# INLINE indexArrM #-}
    freezeArr = freezeUnliftedArray
    {-# INLINE freezeArr #-}
    thawArr = thawUnliftedArray
    {-# INLINE thawArr #-}
    unsafeFreezeArr = unsafeFreezeUnliftedArray
    {-# INLINE unsafeFreezeArr #-}
    unsafeThawArr (UnliftedArray arr#) = primitive ( \ s0# ->
            let !(# s1#, marr# #) = unsafeThawArray# (unsafeCoerce# arr#) s0#
                                                        -- ArrayArray# and Array# use the same representation
            in (# s1#, MutableUnliftedArray (unsafeCoerce# marr#) #)    -- so this works
        )
    {-# INLINE unsafeThawArr #-}

    copyArr = copyUnliftedArray
    {-# INLINE copyArr #-}
    copyMutableArr = copyMutableUnliftedArray
    {-# INLINE copyMutableArr #-}

    moveArr marr1 s1 marr2 s2 l
        | l <= 0 = return ()
        | sameMutableUnliftedArray marr1 marr2 =
            case compare s1 s2 of
                LT ->
                    let !d = s2 - s1
                        !s2l = s2 + l
                        go !i | i >= s2l = return ()
                              | otherwise = do x <- readUnliftedArray marr2 i
                                               writeUnliftedArray marr1 (i-d) x
                                               go (i+1)
                    in go s2

                EQ -> return ()

                GT ->
                    let !d = s1 - s2
                        go !i | i < s2 = return ()
                              | otherwise = do x <- readUnliftedArray marr2 i
                                               writeUnliftedArray marr1 (i+d) x
                                               go (i-1)
                    in go (s2+l-1)
        | otherwise = copyMutableUnliftedArray marr1 s1 marr2 s2 l
    {-# INLINE moveArr #-}

    cloneArr = cloneUnliftedArray
    {-# INLINE cloneArr #-}
    cloneMutableArr = cloneMutableUnliftedArray
    {-# INLINE cloneMutableArr #-}

    resizeMutableArr marr n = do
        marr' <- newUnliftedArray n uninitialized
        copyMutableUnliftedArray marr' 0 marr 0 (sizeofMutableUnliftedArray marr)
        return marr'
    {-# INLINE resizeMutableArr #-}
    shrinkMutableArr _ _ = return ()
    {-# INLINE shrinkMutableArr #-}

    sameMutableArr = sameMutableUnliftedArray
    {-# INLINE sameMutableArr #-}
    sizeofArr = sizeofUnliftedArray
    {-# INLINE sizeofArr #-}
    sizeofMutableArr = return . sizeofMutableUnliftedArray
    {-# INLINE sizeofMutableArr #-}

    sameArr (UnliftedArray arr1#) (UnliftedArray arr2#) = isTrue# (
        sameMutableArrayArray# (unsafeCoerce# arr1#) (unsafeCoerce# arr2#))
    {-# INLINE sameArr #-}

--------------------------------------------------------------------------------

-- | Yield a pointer to the array's data and do computation with it.
--
-- This operation is only safe on /pinned/ primitive arrays allocated by 'newPinnedPrimArray' or
-- 'newAlignedPinnedPrimArray'.
--
-- Don't pass a forever loop to this function, see <https://ghc.haskell.org/trac/ghc/ticket/14346 #14346>.
withPrimArrayContents :: PrimArray a -> (Ptr a -> IO b) -> IO b
{-# INLINE withPrimArrayContents #-}
withPrimArrayContents (PrimArray ba#) f = do
    let addr# = byteArrayContents# ba#
        ptr = Ptr addr#
    b <- f ptr
    primitive_ (touch# ba#)
    return b

-- | Yield a pointer to the array's data and do computation with it.
--
-- This operation is only safe on /pinned/ primitive arrays allocated by 'newPinnedPrimArray' or
-- 'newAlignedPinnedPrimArray'.
--
-- Don't pass a forever loop to this function, see <https://ghc.haskell.org/trac/ghc/ticket/14346 #14346>.
withMutablePrimArrayContents :: MutablePrimArray RealWorld a -> (Ptr a -> IO b) -> IO b
{-# INLINE withMutablePrimArrayContents #-}
withMutablePrimArrayContents (MutablePrimArray mba#) f = do
    let addr# = byteArrayContents# (unsafeCoerce# mba#)
        ptr = Ptr addr#
    b <- f ptr
    primitive_ (touch# mba#)
    return b


-- | Cast between arrays
castArray :: (Arr arr a, Cast a b) => arr a -> arr b
castArray = unsafeCoerce#


-- | Cast between mutable arrays
castMutableArray :: (Arr arr a, Cast a b) => MArr arr s a -> MArr arr s b
castMutableArray = unsafeCoerce#
