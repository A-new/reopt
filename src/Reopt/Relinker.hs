{-|
Module      : Reopt.Relinker
Copyright   : (c) Galois Inc, 2016
License     : None
Maintainer  : jhendrix@galois.com

This module is a start towards a binary and object merging tool.
-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}
module Reopt.Relinker
  ( CodeRedirection(..)
  , mergeObject
  ) where

import           Control.Exception (assert)
import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State
import           Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Bld
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Internal
import qualified Data.ByteString.Lazy as BSL
import           Data.Elf
import           Data.Foldable
import           Data.Int
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Monoid
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Storable.Mutable as SMV
import           Data.Word
import           Numeric (showHex)
import           System.Random

import qualified Reopt.Relinker.RangeSet as RS
import           Reopt.Relinker.Redirection

import Debug.Trace

------------------------------------------------------------------------
-- Utilities

-- | @fixAlignment v a@ returns the smallest multiple of @a@
-- that is not less than @v@.
fixAlignment :: Integral w => w -> w -> w
fixAlignment v 0 = v
fixAlignment v 1 = v
fixAlignment v a0
    | m == 0 = c * a
    | otherwise = (c + 1) * a
  where a = fromIntegral a0
        (c,m) = v `divMod` a

mapFromList :: Ord k => (a -> k) -> [a] -> Map k [a]
mapFromList proj = foldr' ins Map.empty
  where ins e = Map.insertWith (++) (proj e) [e]

-- | Returns true if this is a power of two or zero.
isPowerOf2 :: Word64 -> Bool
isPowerOf2 w = w .&. (w-1) == 0


hasBits :: Bits x => x -> x -> Bool
x `hasBits` b = (x .&. b) == b

writeBS :: SV.MVector s Word8 -> Int -> BS.ByteString -> ST s ()
writeBS mv base bs = do
  let len = BS.length bs
  when (SMV.length mv < base + len) $ do
    fail $ "Bytestring overflows buffer."
  forM_ [0..len-1] $ \i -> do
    SMV.write mv (base+i) (bs `BS.index` i)


write32_lsb :: SMV.MVector s Word8 -> Word64 -> Word32 -> ST s ()
write32_lsb v a c = do
  -- Assert there are at least
  assert (a <= -4) $ do
  let i = fromIntegral a
  SMV.write v i     $ fromIntegral c
  SMV.write v (i+1) $ fromIntegral (c `shiftR`  8)
  SMV.write v (i+2) $ fromIntegral (c `shiftR` 16)
  SMV.write v (i+3) $ fromIntegral (c `shiftR` 24)

------------------------------------------------------------------------
-- Elf specific utilities

-- | Size of page on system 
page_size :: Word64
page_size = 0x1000

-- | Get the alignment that loadable segments seem to respect in a binary.
elfAlignment :: Num w => Elf w -> w
elfAlignment e =
    case loadableSegments of
      [] -> 0
      (s:_) -> elfSegmentAlign s
  where isLoadable s = elfSegmentType s == PT_LOAD
        loadableSegments = filter isLoadable $ elfSegments e


-- | Return the name of a symbol as a string (or <unamed symbol> if not defined).
steStringName :: ElfSymbolTableEntry w -> String
steStringName sym
  | BS.null (steName sym) = "<unnamed symbol>"
  | otherwise = BSC.unpack (steName sym)            


reservedAddrs :: ElfLayout Word64 -> Either String (RS.RangeSet Word64)
reservedAddrs l = foldl' f (Right RS.empty) (allPhdrs l)
  where
        f :: Either String (RS.RangeSet Word64)
          -> Phdr Word64
          -> Either String (RS.RangeSet Word64)
        f (Left msg) _ = Left msg
        f (Right m) p = do
          let seg = phdrSegment p
          case elfSegmentType seg of
             PT_LOAD -> Right $ RS.insert low high m
               where low = elfSegmentVirtAddr seg
                     high = low + phdrMemSize p - 1
             PT_DYNAMIC -> Left "Dynamic elf files not yet supported."
             _ -> Right m

hasSectionName :: ElfSection w -> String -> Bool
s `hasSectionName` nm = elfSectionName s == nm


tryFindSectionIndex :: V.Vector (ElfSection w) -> String -> [Int]
tryFindSectionIndex sections nm =
  V.toList (V.findIndices (`hasSectionName` nm) sections)

findSectionIndex :: Monad m => V.Vector (ElfSection w) -> String -> m (Maybe Int)
findSectionIndex sections nm =
  case tryFindSectionIndex sections nm of
    [i] -> return $! Just i
    []  -> return Nothing
    _   -> fail $ "Multiple " ++ nm ++ " sections in object file."

-- | Return segment used to indicate the stack can be non-executable.
gnuStackSegment :: Num w => PhdrIndex -> ElfSegment w
gnuStackSegment idx =
  ElfSegment { elfSegmentType     = PT_GNU_STACK
             , elfSegmentFlags    = pf_r .|. pf_w
             , elfSegmentIndex    = idx
             , elfSegmentVirtAddr = 0
             , elfSegmentPhysAddr = 0
             , elfSegmentAlign    = 0
             , elfSegmentMemSize  = ElfRelativeSize 0
             , elfSegmentData     = Seq.empty
             }

elfHasTLSSegment :: Elf w -> Bool
elfHasTLSSegment e =
  case filter (`segmentHasType` PT_TLS) (elfSegments e) of
    [] -> False
    [_] -> True
    _ -> error "Multiple TLS segments in original binary"

elfHasTLSSection :: (Num w, Bits w) => Elf w -> Bool
elfHasTLSSection e =
  any (\s -> elfSectionFlags s `hasBits` shf_tls) (e^..elfSections)

segmentHasType :: ElfSegment w -> ElfSegmentType -> Bool
segmentHasType s tp = elfSegmentType s == tp

-- | Return total number of segments expected in original binary.
loadableSegmentCount :: Elf w -> Int
loadableSegmentCount e = length $ filter (`segmentHasType` PT_LOAD) (elfSegments e)

elfHasGNUStackSegment :: Elf w -> Bool
elfHasGNUStackSegment e =
  any (`segmentHasType` PT_GNU_STACK) (elfSegments e)

elfHasGNUStackSection :: Elf w -> Bool
elfHasGNUStackSection e =
  any (\s -> elfSectionName s == ".note.GNU-stack") (e^..elfSections)


findSectionFromHeaders :: String -> ElfHeaderInfo w -> [ElfSection w]
findSectionFromHeaders nm info =
  filter (\s -> elfSectionName s == nm) $ V.toList $ getSectionTable info

------------------------------------------------------------------------
-- SymbolTable

  
type SymbolTable w = V.Vector (ElfSymbolTableEntry w)

-- | Offset of entry in symbol table.
type SymbolTableIndex = Word32

-- | Get symbol by name.
getSymbolByIndex :: SymbolTable w -> SymbolTableIndex -> ElfSymbolTableEntry w
getSymbolByIndex sym_table sym_index
  | sym_index >= fromIntegral (V.length sym_table) =
    error $ "Symbolic offset " ++ show sym_index ++ " is out of range."
  | otherwise = sym_table V.! fromIntegral sym_index


------------------------------------------------------------------------
-- SectionMap

-- | Map from section indices in object to virtual address where it will be
-- loaded into binary.
type SectionMap w = Map ElfSectionIndex w

-- | Return address that
getSectionBase :: SectionMap w -> ElfSectionIndex -> w
getSectionBase m i = fromMaybe (error msg) $ Map.lookup i m
  where msg = "Symbol table points to section " ++ show i ++ " not being mapped to binary."

------------------------------------------------------------------------
-- BinarySymbolMap

-- | Maps symbol names in binaries to their virtual address when loaded.
type BinarySymbolMap w = Map BS.ByteString w 


symbolNameAddr :: ElfSymbolTableEntry w -> Maybe (BS.ByteString, w)
symbolNameAddr sym =
  if steType sym `elem` [ STT_OBJECT, STT_FUNC ] then
    Just (steName sym, steValue sym)
   else
    Nothing

-- | Create a binary symbol map from the symbol table of the elf file if it exists.
createBinarySymbolMap :: ElfHeaderInfo w -> BinarySymbolMap w
createBinarySymbolMap binary = do
  case ".symtab" `findSectionFromHeaders` binary of
     -- Assume that no section means no relocations
    []  -> Map.empty
    [s] -> Map.fromList $ mapMaybe symbolNameAddr $ getSymbolTableEntries binary s
    _   -> error $ "Multple .symtab sections in bianry file."

------------------------------------------------------------------------
-- ObjectRelocationInfo

-- | Information needed to perform relocations in the new binary.
data ObjectRelocationInfo w
   = ObjectRelocationInfo
     { objectSectionMap :: !(SectionMap w)
       -- ^ Maps loaded sections in the new object to their address.
     , binarySymbolMap :: !(BinarySymbolMap w)
     }

objectSectionAddr :: String
                  -> ElfSectionIndex
                  -> ObjectRelocationInfo w
                  -> Either String w
objectSectionAddr src idx info = 
  case Map.lookup idx (objectSectionMap info) of
    Nothing ->
      Left $ src ++ "refers to an unmapped section index " ++ show idx ++ "."
    Just r ->
      Right r

-- | Get the address of a symbol table if it is mapped in the section map.
symbolAddr :: (Eq w, Num w)
           => ObjectRelocationInfo w
              -- ^ Information needed for relocations.
           -> String
              -- ^ Name of reference to a symbol
           -> ElfSymbolTableEntry w
           -> Either String w
symbolAddr reloc_info src sym =
  case steType sym of
    STT_SECTION
      | steValue sym /= 0 ->
        Left "symbolAddr expects section names to have 0 offset."
      | steIndex sym == SHN_UNDEF ->
        Left "Reference to undefined section."
      | otherwise ->
          objectSectionAddr src (steIndex sym) reloc_info
    STT_FUNC
      | steIndex sym == SHN_UNDEF ->
        Left "Function symbol has undefined section."
      | otherwise ->
          objectSectionAddr src (steIndex sym) reloc_info
    STT_NOTYPE
      | steIndex sym /= SHN_UNDEF ->
          Left "Expected STT_NOTYPE symbol to refer to SHN_UNDEF section."
      | otherwise ->
        case Map.lookup (steName sym) (binarySymbolMap reloc_info) of
          Nothing -> Left $ "Could not resolve symbol " ++ BSC.unpack (steName sym) ++ "."
          Just addr -> Right addr
    tp -> error $ "symbolAddr does not support symbol with type " ++ show tp ++ "." 

------------------------------------------------------------------------
-- Code for performing relocations in new object.

-- | Perform a relocation listed in the new object.
performReloc :: ObjectRelocationInfo Word64
                -- ^ Inforation about the object and binary needed to resolve symbol
                -- addresses.
             -> SymbolTable Word64
                -- ^ A vector listing the elf symbols in the object.
                -- 
                -- This allows one to find the symbol associated with a
                -- given relocation.
             -> Word64
                -- ^ Base offset of this section.
             -> SV.MVector s Word8
                -- ^ Contents of elf section we are apply this to.
             -> RelaEntry X86_64_RelocationType
                -- ^ The relocation entry.
             -> ST s ()
performReloc reloc_info sym_table this_vaddr mv reloc = do
  -- Offset to modify.
  let off = r_offset reloc :: Word64
  let sym = getSymbolByIndex sym_table (r_sym reloc)
  -- Get the address of a symbol
  let sym_val =
          case symbolAddr reloc_info "A relocation entry" sym of
            Right v -> v
            Left msg -> error msg
        where sym  = getSymbolByIndex sym_table (r_sym reloc)
  -- Relocation addend
  let addend = r_addend reloc :: Int64
  -- Get PC offset
  let pc_offset = this_vaddr + off
  -- Parse on type
  case r_type reloc of
    R_X86_64_PC32 ->
          write32_lsb mv off res32
      where res64 = sym_val + fromIntegral addend - pc_offset :: Word64
            res32 = fromIntegral res64 :: Word32
    R_X86_64_32
        | fromIntegral res32 /= res64 ->
          error $ "Relocation of " ++ steStringName sym
             ++ " at " ++ showHex sym_val " + " ++ show addend
             ++ " does not safely zero extend."
        | otherwise ->
          write32_lsb mv off res32
      where res64 = sym_val + fromIntegral addend :: Word64
            res32 = fromIntegral res64 :: Word32
    R_X86_64_32S
        | fromIntegral res32 /= res64 ->
          error $ "Relocation of " ++ steStringName sym
             ++ " at " ++ showHex sym_val " + " ++ show addend
             ++ " does not safely sign extend."
        | otherwise ->
          write32_lsb mv off (fromIntegral res32)
      where res64 = fromIntegral sym_val + addend :: Int64
            res32 = fromIntegral res64 :: Int32
    _ -> do
      error "Relocation not supported"

performRelocs :: ObjectRelocationInfo Word64
                -- ^ Maps elf section indices in object to the base virtual address
                -- in the binary.
              -> V.Vector (ElfSymbolTableEntry Word64)
                 -- ^ Elf symbol table
              -> ElfSection Word64
                 -- ^ Section that we are applying relocation to.
              -> Word64 -- ^ Base address of this section.
              -> [RelaEntry X86_64_RelocationType]
              -> ElfSection Word64
performRelocs reloc_info sym_table section this_vaddr relocs = runST $ do
  let dta = elfSectionData section
  let len = BS.length dta
  mv <- SMV.new len
  -- Copy original bytes into bytestring
  writeBS mv 0 dta
  -- Updpate using relocations
  mapM_ (performReloc reloc_info sym_table this_vaddr mv) relocs

  let SMV.MVector _ fp = mv
  let reloc_data = Data.ByteString.Internal.fromForeignPtr fp 0 len
  return $! section { elfSectionAddr = this_vaddr
                    , elfSectionData = reloc_data
                    }

------------------------------------------------------------------------
-- NameToSymbolMap

-- | Maps names to symbol in binary.
type NameToSymbolMap w = Map BS.ByteString [ElfSymbolTableEntry w]

-- | Get symbol by name.
getSymbolByName :: NameToSymbolMap w -> BS.ByteString -> ElfSymbolTableEntry w
getSymbolByName m nm =
  case Map.lookup nm m of
    Just [entry] -> entry
    Just _ -> error $ "The symbol name " ++ BSC.unpack nm ++ " is ambiguous."
    Nothing -> error $ "Could not find symbol name " ++ BSC.unpack nm ++ "."

------------------------------------------------------------------------
-- ResolvedRedirs

-- | Information needed to insert jumps to new code in binary.
data ResolvedRedirs w = CR { crMkJump :: !(w -> BS.ByteString)
                             -- ^ Create a jump instruction to the given address.
                           , crRelocInfo  :: !(ObjectRelocationInfo w)
                             -- ^ Maps elf section indices in object to the base virtual address
                             -- in the binary.
                           , crSymbols :: !(NameToSymbolMap w)
                             -- ^ Maps symbol names in the object to the associated symbol.
                           , crPhdrBase :: !PhdrIndex
                             -- ^ Offset to add to phds.
                           , crEntries :: !(Map PhdrIndex [CodeRedirection w])
                             -- ^ Get the list of redirections to apply.
                           }

-- | This takes a bytestring in the original binary and updates it with relocations
-- to point to the new binary.
remapBytes :: forall w
           .  Integral w
           => ResolvedRedirs w
           -> [CodeRedirection w]
              -- ^ List of redirections to apply
           -> w
              -- ^ File offset in segment
           -> BS.ByteString
           -> BS.ByteString
remapBytes redirs redir_list base bs = runST $ do
  let len :: Int
      len = BS.length bs
  mv <- SMV.new len
  -- Copy original bytes into bytestring
  writeBS mv 0 bs
  -- Apply relocations.
  let reloc_info = crRelocInfo redirs
  let sym_table = crSymbols redirs
  forM_ redir_list $ \entry -> do
    let off = redirSourceOffset entry
    let sym = getSymbolByName sym_table $ redirTarget entry
    when (base <= off && off < base + fromIntegral len) $ do
      let tgt =
            case symbolAddr reloc_info "A user defined relocation" sym of
              Right r -> r
              Left msg -> error msg
      writeBS mv (fromIntegral (off - base)) (crMkJump redirs tgt)

  let SMV.MVector _ fp = mv
  return $! Data.ByteString.Internal.fromForeignPtr fp 0 len



rawSegmentFromBuilder :: (Bits w, Integral w)
                      => ElfLayout w
                      -> ResolvedRedirs w
                      -> [CodeRedirection w]
                         -- ^ Redirections for this segment
                      -> w -- ^ Offset in segment for this data
                      -> BS.ByteString
                      -> [ElfDataRegion w]
                      -> Either String (w, [ElfDataRegion w])
rawSegmentFromBuilder orig_layout redirs entries off bs rest = do
  let off' = off + fromIntegral (BS.length bs)
  (off2, prev) <- mapOrigLoadableRegions orig_layout redirs entries off' rest
  return (off2, ElfDataRaw (remapBytes redirs entries off bs) : prev)

mapLoadableSection :: (Bits w, Integral w)
                   => ElfLayout w
                   -> ResolvedRedirs w
                   -> [CodeRedirection w]
                   -> w -- ^ Offset in segment for this section
                   -> ElfSection w
                   -> [ElfDataRegion w]
                   -> Either String (w, [ElfDataRegion w])
mapLoadableSection orig_layout redirs entries off sec rest = do
  let bs = elfSectionData sec
  let off' = off + fromIntegral (BS.length bs)
  let sec' = sec { elfSectionName = ".orig" ++ elfSectionName sec
                 , elfSectionData = remapBytes redirs entries off bs
                 }
  seq sec' $ do
  (off2, prev) <- mapOrigLoadableRegions orig_layout redirs entries off' rest
  return (off2, ElfDataSection sec' : prev)


-- | This traverses elf data regions in an loadable elf segment.
mapOrigLoadableRegions :: (Bits w, Integral w)
                       => ElfLayout w
                          -- ^ Layout created for original binary.
                       -> ResolvedRedirs w
                       -> [CodeRedirection w]
                          -- ^ Redirections for segment.
                       -> w -- ^ Offset in segment for region
                       -> [ElfDataRegion w]
                       -> Either String (w, [ElfDataRegion w])
mapOrigLoadableRegions _ _ _ off [] =
  return (off, [])
mapOrigLoadableRegions orig_layout redirs entries off (reg:rest) =
  case reg of
    ElfDataElfHeader -> do
      let b = BSL.toStrict $ Bld.toLazyByteString $ buildElfHeader orig_layout
      rawSegmentFromBuilder orig_layout redirs entries off b rest
    ElfDataSegmentHeaders -> do
      let b = BSL.toStrict $ Bld.toLazyByteString $
                buildElfSegmentHeaderTable orig_layout
      rawSegmentFromBuilder orig_layout redirs entries off b rest
    -- Flatten special segments
    ElfDataSegment seg  ->
      case elfSegmentType seg of
        -- Copy TLS segment
        PT_TLS -> do
          let subseg = toList (elfSegmentData seg)
          (off2, subseg1) <- mapOrigLoadableRegions orig_layout redirs entries off subseg
          let tls_seg = seg { elfSegmentIndex = crPhdrBase redirs + elfSegmentIndex seg
                            , elfSegmentData  = Seq.fromList subseg1
                            }

          (off3, rest1) <- mapOrigLoadableRegions orig_layout redirs entries off2 rest
          return $! (off3, ElfDataSegment tls_seg : rest1)

        _ -> do
          let subseg = toList (elfSegmentData seg)
          mapOrigLoadableRegions orig_layout redirs entries off (subseg ++ rest)

    ElfDataSectionHeaders ->
      Left "Did not expect section headers in loadable region"
    ElfDataSectionNameTable ->
      Left "Did not expect section name table in loadable region"
    ElfDataGOT g ->
      mapLoadableSection orig_layout redirs entries off (elfGotSection g) rest
    ElfDataSection s -> do
      mapLoadableSection orig_layout redirs entries off s rest
    ElfDataRaw b ->
      rawSegmentFromBuilder orig_layout redirs entries off b rest

------------------------------------------------------------------------
-- MergerState

data MergerState = MS { _mergerGen :: !StdGen
                      , _mergerReserved :: !(RS.RangeSet Word64)
                      }

mergerGen :: Simple Lens MergerState StdGen
mergerGen = lens _mergerGen (\s v -> s { _mergerGen = v})

mergerReserved :: Simple Lens MergerState (RS.RangeSet Word64)
mergerReserved = lens _mergerReserved (\s v -> s { _mergerReserved = v })

------------------------------------------------------------------------
-- Merger

type Merger = State MergerState

runMerger :: ElfHeaderInfo Word64
          -> StdGen
          -> Merger a
          -> Either String (a, StdGen)
runMerger e gen m = do
  case reservedAddrs (elfLayout (getElf e)) of
    Left msg -> Left msg
    Right s -> Right $! (a,ms'^.mergerGen)
      where ms = MS { _mergerGen = gen
                    , _mergerReserved = s
                    }
            (a,ms') = runState m ms
      
-- | Given a region this finds a new random address to store this.
findNewAddress :: Word64
                  -- ^ A power of two that is the modulus used in alignment
                  -- calculations
               -> Word64
                  -- ^ Size of space to reserve
               -> Word64
                  -- ^ The offset in the file where this will be added.
               -> Merger Word64
findNewAddress 0 size file_offset = do
  findNewAddress 1 size file_offset
findNewAddress align size file_offset = do
  reserved <- use mergerReserved
  when (not (isPowerOf2 align)) $ do
    fail $ "Elf alignment should be power of two."
  let page_mask = page_size - 1
  -- Round up to next multiple of a page.
  let adjusted_offset = (file_offset + page_mask) .&. complement page_mask
  -- Get regions currently loaded.
  g <- use mergerGen
  -- Mask to restrict addresses to be less than 2^30
  let low_mask = 2^(30::Word64) - 1

  let (r,g') = random g
  mergerGen .= g'
  -- The 
  let addr = (r .&. low_mask .&. complement (align - 1))
           .|. (adjusted_offset  .&. (align - 1))
  let isGood = addr /= 0 && not (RS.overlaps addr (addr + size) reserved)
  if isGood then do
    -- Add to reserved.
    mergerReserved %= RS.insert addr (addr + size)
    return addr
   else
    -- Try again
    findNewAddress align size file_offset


-- | Find relocation entries in section with given name.
findRelaEntries :: Monad m
                => Elf Word64
                   -- ^ Object with relocations
                -> String
                   -- ^ Name of section containing relocation entries.
                -> m [RelaEntry X86_64_RelocationType]
findRelaEntries obj nm = do
  case nm `findSectionByName` obj of
    -- Assume that no section means no relocations
    [] -> return []
    [s] ->
      return $! elfRelaEntries (elfData obj) (elfSectionData s)
    _ -> fail$  "Multple " ++ show nm ++ " sections in object file."

-- | Find relocation entries in section with given name.
findSymbolTable :: Monad m
                => ElfHeaderInfo Word64
                   -- ^ Object with relocations
                -> m (V.Vector (ElfSymbolTableEntry Word64))
findSymbolTable obj = do
  case ".symtab" `findSectionFromHeaders` obj of
    -- Assume that no section means no relocations
    []  -> fail $ "Could not find symbol table."
    [s] -> return $! V.fromList $ getSymbolTableEntries obj s
    _   -> fail $ "Multple .symtab sections in object file."

checkOriginalBinaryAssumptions :: Monad m => Elf Word64 -> m ()
checkOriginalBinaryAssumptions binary = do
  when (elfData binary /= ELFDATA2LSB) $ do
    error $ "Expected least-significant bit first elf."
  when (elfType binary /= ET_EXEC) $ do
    fail $ "Expected a relocatable file as input."
  when (elfData binary /= ELFDATA2LSB) $ do
    fail $ "Expected the original binary to be least-significant bit first."
  when (elfType binary /= ET_EXEC) $ do
    fail $ "Expected the original binary is an executable."
  when (elfRelroRange binary /= Nothing) $ do
    fail $ "Expected no PT_GNU_RELO segment in binary."
  when (elfFlags binary /= 0) $ do
    fail $ "Expected elf flags in binary to be zero."

checkObjAssumptions :: Monad m
                    => Elf Word64
                    -> ElfOSABI
                    -> m ()
checkObjAssumptions obj expected_osabi = do
  -- Check new object properties.
  when (elfData obj /= ELFDATA2LSB) $ do
    fail $ "Expected the new binary binary to be least-significant bit first."
  when (elfType obj /= ET_REL) $ do
    fail $ "Expected a relocatable file as input."
  when (elfOSABI obj /= expected_osabi) $ do
    fail $ "Expected the new object to use the same OS ABI as original."
  when (elfMachine obj /= EM_X86_64) $ do
    fail $ "Only x86 64-bit executables are supported."
  when (elfRelroRange obj /= Nothing) $ do
    fail $ "Expected no PT_GNU_RELO segment in new object."
  when (elfFlags obj /= 0) $ do
    fail $ "Expected elf flags in new object to be zero."


didNotExpectOriginalRegion :: String -> Either String a
didNotExpectOriginalRegion region_name =
  Left $ "Did not expect " ++ region_name ++ " in original binary."

data OriginalBinaryInfo w = OBI { _obiRegions :: !(Seq (ElfDataRegion w))
                                }

obiRegions :: Simple Lens (OriginalBinaryInfo w) (Seq (ElfDataRegion w))
obiRegions = lens _obiRegions (\s v -> s { _obiRegions = v })

initOriginalBinaryInfo :: OriginalBinaryInfo w
initOriginalBinaryInfo =
  OBI { _obiRegions = Seq.empty
      }


copyOriginalBinaryRegion :: forall w
                          . (Bits w, Integral w, Show w)
                         => ElfLayout w
                         -> ResolvedRedirs w
                            -- ^ Redirections in code
                         -> (w, OriginalBinaryInfo w)
                         -> ElfDataRegion w
                         -> Either String (w,OriginalBinaryInfo w)
copyOriginalBinaryRegion orig_layout redirs (file_offset, info) reg =
  case reg of
    -- Drop elf data header.
    ElfDataElfHeader ->
      return (file_offset, info)
    -- Drop segment headers
    ElfDataSegmentHeaders ->
      return (file_offset, info)
    ElfDataSegment seg ->
      case elfSegmentType seg of
        PT_LOAD -> do
          let sub_reg = toList (elfSegmentData seg)
          let idx = elfSegmentIndex seg
          let entries = fromMaybe [] $! Map.lookup idx (crEntries redirs)
          (_,sub_reg') <- mapOrigLoadableRegions orig_layout redirs entries 0 sub_reg
          let seg' = seg { elfSegmentIndex = crPhdrBase redirs + elfSegmentIndex seg
                         , elfSegmentData = Seq.fromList sub_reg'
                         }
          let a  = elfSegmentAlign seg
              mask = a  - 1
              req_align = elfSegmentVirtAddr seg .&. mask
              act_align = file_offset .&. mask
          trace ("Computing padding " ++ show (showHex a "", showHex act_align "", showHex req_align "")) $ do
          -- Compute amount of padding to get alignment correct.
          let padding :: w
              padding | a <= 1 = 0
                      | act_align <= req_align = req_align - act_align
                        -- Need to insert padding to wrap around.
                      | otherwise = (a - act_align) + req_align

          let new_segs = dataPadding padding ++ [ ElfDataSegment seg' ]
          let file_offset' = file_offset + padding + elfRegionFileSize orig_layout reg
          let info' = info & obiRegions %~ (Seq.>< Seq.fromList new_segs)
          return $! (file_offset', info')
        -- Drop non-loaded segments
        _ ->
          return (file_offset, info)
    -- Drop section headers
    ElfDataSectionHeaders ->
      return (file_offset, info)
    -- Drop section name table
    ElfDataSectionNameTable ->
      return (file_offset, info)
    ElfDataGOT _ ->
      didNotExpectOriginalRegion "top-level .got table"
    -- Drop unloaded sections
    ElfDataSection _ -> do
      return (file_offset, info)
    -- Drop bytes outside a loadable segment.
    ElfDataRaw _ -> do
      return (file_offset, info)

copyOriginalBinaryRegions :: forall w
                           . (Bits w, Integral w, Show w)
                          => Elf w
                          -> ResolvedRedirs w
                          -> w  -- ^ Offset of file.
                          -> Either String (OriginalBinaryInfo w)
copyOriginalBinaryRegions orig_binary redirs base_offset = do
  let orig_layout = elfLayout orig_binary
  let f :: (w, OriginalBinaryInfo w)
        -> ElfDataRegion w
        -> Either String (w, OriginalBinaryInfo w)
      f = copyOriginalBinaryRegion orig_layout redirs
        
  snd <$> foldlM f (base_offset, initOriginalBinaryInfo) (orig_binary^.elfFileData)

-- | Make padding region if number of bytes is non-zero.
dataPadding :: Integral w => w -> [ElfDataRegion w]
dataPadding 0 = []
dataPadding z = [ ElfDataRaw (BS.replicate (fromIntegral z) 0) ]


data NewObjectInfo w
  = NewObjectInfo { noiElf :: !(Elf w)
                    -- ^ Elf for object
                  , noiSections :: !(V.Vector (ElfSection w))
                    -- ^ Vector of sections in List of all sections
                  , noiRelocInfo :: !(ObjectRelocationInfo w)
                  , noiSymbols :: !(V.Vector (ElfSymbolTableEntry w))
                  }

-- | Create region for section in new object.
createRegionsForSection :: Monad m
                        => NewObjectInfo Word64
                           -- ^ Information about new object
                        -> ElfSectionFlags Word64
                           -- ^ Expected flags
                        -> NewSectionBounds Word64
                           -- ^ Section if we need to.
                        -> String
                           -- ^ Name of relocation section.
                        -> Word64
                           -- ^ Base address of segment
                        -> m [ElfDataRegion Word64]
createRegionsForSection _         _     NSBUndefined{} _ _ = return []
createRegionsForSection obj_info flags (NSBDefined sec_idx pad prev_size _) rela_name base_seg_addr = do
  let obj        = noiElf        obj_info
      sections   = noiSections   obj_info
      reloc_info = noiRelocInfo obj_info
      syms       = noiSymbols    obj_info
  let sec = sections V.! sec_idx
  when (elfSectionType sec /= SHT_PROGBITS) $ do
    fail $ elfSectionName sec ++ " section has unexpected type."
  when (not (elfSectionFlags sec `hasBits` flags)) $ do
    fail $ elfSectionName sec ++ " section has unexpected permissions."
  -- Find text relocations section
  relocs <- findRelaEntries obj rela_name
  -- Perform relocations
  let off = prev_size `fixAlignment` elfSectionAddrAlign sec

  let addr = base_seg_addr + off
  let reloc_sec = performRelocs reloc_info syms sec addr relocs
  -- Get padding to add between end of header and start of code section.
  return $! dataPadding pad ++ [ ElfDataSection reloc_sec ]

-- | Create a bytestring with a jump to the immediate address.
x86_64_immediate_jmp :: Word64 -> BS.ByteString
x86_64_immediate_jmp addr = BSL.toStrict $ Bld.toLazyByteString $ mov_addr_to_r11 <> jump_r11
  where mov_addr_to_r11
          =  Bld.word8 0x49
          <> Bld.word8 0xBB
          <> Bld.word64LE addr
        jump_r11
          =  Bld.word8 0x41
          <> Bld.word8 0xFF
          <> Bld.word8 0xE3
   

-- | This merges an existing elf binary and new header with a list of redirections.
mergeObject :: ElfHeaderInfo Word64
               -- ^ Existing binary
            -> ElfHeaderInfo Word64
               -- ^ Object file to insert
            -> [CodeRedirection Word64]
               -- ^ Redirections to apply to original file for new file.
            -> StdGen
               -- ^ generator for getting offset
            -> Either String (Elf Word64, StdGen)
mergeObject orig_binary new_obj redirs gen =
  runMerger orig_binary gen $
    mergeObject' orig_binary new_obj redirs x86_64_immediate_jmp

data NewSectionBounds w
  = NSBDefined !Int !w !w !w
    -- ^ Section index, amount of padding, file start, and file end.
    -- File offset is relative to new segment.
  | NSBUndefined !w
    -- ^ Offset where section would have started/ended.

nsb_end :: NewSectionBounds w -> w
nsb_end (NSBDefined _ _ _ e) = e
nsb_end (NSBUndefined o) = o        


nsb_entries :: Integral w => NewSectionBounds w -> w -> [(ElfSectionIndex, w)]
nsb_entries NSBUndefined{} _ = []
nsb_entries (NSBDefined idx _ start _) base =
  [ (,) (fromIntegral idx) (base + start)
  ]

-- | Returns the file start and end of a section given an index of
-- the section or nothing if it is not defined.
get_section_bounds :: Integral w
                   => V.Vector (ElfSection w) -- ^ List of sections
                   -> w -- ^ End of last section
                   -> Maybe Int -- ^ Index of Section (or nothing) if we don't add section.
                   -> NewSectionBounds w
get_section_bounds _ off Nothing  = NSBUndefined off
get_section_bounds sections off (Just idx) = NSBDefined idx pad off' (off' + sz)
  where s = sections V.! idx
        pad  = fromIntegral (off' - off)
        off' = off `fixAlignment` elfSectionAddrAlign s
        sz   = elfSectionFileSize s

findSectionBounds :: (Monad m, Integral w)
                  => V.Vector (ElfSection w) -- ^ List of sections
                  -> w -- ^ Enf of last section
                  -> String -- ^ Name of section
                  -> m (NewSectionBounds w)
findSectionBounds sections off nm = do
  get_section_bounds sections off <$> findSectionIndex sections nm



mergeObject' :: ElfHeaderInfo Word64 -- ^ Existing binary
             -> ElfHeaderInfo Word64 -- ^ Information about object file to insert
             -> [CodeRedirection Word64] -- ^ Redirections
             -> (Word64 -> BS.ByteString)
                -- ^ Function for creating jump to given offset.
             -> Merger (Elf Word64)
mergeObject' orig_binary_header obj_header redirs mkJump = do
  trace "mergObject'0" $ do
  let orig_binary = getElf orig_binary_header
  let elf_class = ELFCLASS64

  -- Check original binary properties
  checkOriginalBinaryAssumptions orig_binary

  let obj = getElf obj_header
  checkObjAssumptions obj (elfOSABI orig_binary)

  let sections = getSectionTable obj_header

  -- Find address for new code.
  let elf_align = elfAlignment orig_binary

  -- Flag indicating whether to add GNU stack segment.
  let add_gnu_stack = elfHasGNUStackSegment orig_binary
                   && elfHasGNUStackSection obj

  -- Flag indicating whether to add TLS segment
  let add_tls = elfHasTLSSegment orig_binary

  when (elfHasTLSSection obj) $ do
    fail $ "TLS section is not allowed in new code object."

  let gnu_stack_index = 2

  let new_phdr_count :: Word16
      new_phdr_count = 2 -- One for executable and one for data.
                    + (if add_gnu_stack then 1 else 0)

  let phdr_count = fromIntegral new_phdr_count
                 + (if add_tls       then 1 else 0)
                 + loadableSegmentCount orig_binary


  let exec_seg_header_size :: Word64
      exec_seg_header_size = fromIntegral (ehdrSize elf_class)
                           + fromIntegral phdr_count * fromIntegral (phdrEntrySize elf_class)

  -- Find text section
  text_sec_bounds     <- findSectionBounds sections exec_seg_header_size ".text"

  trace (".textbounds    " ++ showHex (nsb_end text_sec_bounds) ".") $ do

  rodata_sec_bounds   <- findSectionBounds sections (nsb_end text_sec_bounds)   ".rodata"

  trace (".rodata bounds " ++ showHex (nsb_end rodata_sec_bounds) ".") $ do
  
  eh_frame_sec_bounds <- findSectionBounds sections (nsb_end rodata_sec_bounds) ".eh_frame"

  trace (".eh_frame bounds " ++ showHex (nsb_end eh_frame_sec_bounds) ".") $ do

  let new_code_seg_filesize = nsb_end eh_frame_sec_bounds
              -- Get size of just new code section
  
  -- Compute offset for new data and ensure it is aligned.
  let new_data_file_offset = new_code_seg_filesize `fixAlignment` page_size
  trace ("data file offset " ++ showHex new_data_file_offset ".") $ do
  
  -- Get bounds of ".data" section.
  data_sec_bounds <- findSectionBounds sections 0                  ".data"
  let post_data_sec_size = nsb_end data_sec_bounds
  -- Compute bounds of ".bss" section.
  bss_sec_bounds  <- findSectionBounds sections post_data_sec_size ".bss"

  let new_data_seg_filesize = nsb_end bss_sec_bounds


  new_code_seg_addr <- findNewAddress elf_align new_code_seg_filesize 0
  new_data_seg_addr <- findNewAddress elf_align new_data_seg_filesize new_data_file_offset

  trace ("Data segment alignment "
         ++ show (showHex new_data_file_offset "", showHex new_data_seg_addr "")) $ do
  -- Map sections to be mapped to

  let reloc_info = ObjectRelocationInfo { objectSectionMap = section_map
                                        , binarySymbolMap = sym_map
                                        }
        where section_map = Map.fromList $
                nsb_entries    text_sec_bounds     new_code_seg_addr
                ++ nsb_entries rodata_sec_bounds   new_code_seg_addr
                ++ nsb_entries eh_frame_sec_bounds new_code_seg_addr
                ++ nsb_entries data_sec_bounds     new_data_seg_addr
                ++ nsb_entries bss_sec_bounds      new_data_seg_addr
              sym_map = createBinarySymbolMap orig_binary_header

  -- Get symbols in object.
  symbols     <- findSymbolTable obj_header

  let obj_info = NewObjectInfo { noiElf = obj
                               , noiSections = sections
                               , noiRelocInfo = reloc_info
                               , noiSymbols = symbols
                               }

  new_code_regions <- do
    let flags = shf_alloc .|. shf_execinstr
    createRegionsForSection obj_info flags text_sec_bounds ".rela.text" new_code_seg_addr

  new_rodata_regions <- do
    let flags = shf_alloc
    createRegionsForSection obj_info flags rodata_sec_bounds ".rela.rodata" new_code_seg_addr
    
  new_ehframe_regions <- do
    let flags = shf_alloc
    createRegionsForSection obj_info flags eh_frame_sec_bounds ".rela.eh_frame" new_code_seg_addr

  -- Create Elf segment

  let gnu_stack_segment_headers
          | add_gnu_stack = [ ElfDataSegment (gnuStackSegment gnu_stack_index) ]
          | otherwise = []


  let exec_seg = ElfSegment
        { elfSegmentType     = PT_LOAD
        , elfSegmentFlags    = pf_r .|. pf_x
        , elfSegmentIndex    = 0
        , elfSegmentVirtAddr = new_code_seg_addr
        , elfSegmentPhysAddr = new_code_seg_addr
        , elfSegmentAlign    = elf_align
        , elfSegmentMemSize  = ElfRelativeSize 0
        , elfSegmentData     = Seq.fromList $
            gnu_stack_segment_headers
            ++ [ ElfDataElfHeader, ElfDataSegmentHeaders ]
            ++ new_code_regions
            ++ new_rodata_regions
            ++ new_ehframe_regions
        }

  new_data_regions <- do
    let flags = shf_alloc .|. shf_write
    createRegionsForSection obj_info flags data_sec_bounds ".rela.data" new_data_seg_addr

  let new_bss_regions =
        case bss_sec_bounds of
          NSBUndefined{} -> []
          NSBDefined i _ _ _ -> reg
            where s   = (sections V.! i)
                  s'  = s { elfSectionAddr = new_data_seg_addr + new_data_seg_filesize }
                  reg = dataPadding (new_data_seg_filesize - post_data_sec_size)
                        ++ [ ElfDataSection s'
                           ]
  let new_bss_size =
        case bss_sec_bounds of
          NSBUndefined{} -> 0
          NSBDefined i _ _ _ -> elfSectionSize s
            where s   = sections V.! i


  trace ("Data padding " ++ show (new_data_file_offset, new_code_seg_filesize)) $ do
  
  -- List of new load segments
  let new_data_segs
          | null data_regions = []
          | otherwise =
             dataPadding (new_data_file_offset - new_code_seg_filesize)
             ++ [ ElfDataSegment seg ]
        where data_regions = new_data_regions
                           ++ new_bss_regions
              seg = ElfSegment
                { elfSegmentType     = PT_LOAD
                , elfSegmentFlags    = pf_r .|. pf_w
                , elfSegmentIndex    = 1
                , elfSegmentVirtAddr = new_data_seg_addr
                , elfSegmentPhysAddr = new_data_seg_addr
                , elfSegmentAlign    = elf_align
                , elfSegmentMemSize  = ElfRelativeSize new_bss_size
                , elfSegmentData     = Seq.fromList data_regions
                }

  let new_regions_end = new_data_file_offset + new_data_seg_filesize
  
  let resolved_redirs =
        CR { crMkJump    = mkJump
           , crRelocInfo = reloc_info
           , crSymbols   = mapFromList steName (V.toList symbols)
           , crPhdrBase  = new_phdr_count
           , crEntries   = mapFromList redirSourcePhdr redirs
           }

  orig_binary_info <-
    case copyOriginalBinaryRegions orig_binary resolved_redirs new_regions_end of
      Left msg -> fail msg
      Right obi -> return obi


  let orig_binary_regions = toList $ orig_binary_info^.obiRegions

  -- Find space for data.
  -- Create new section and segment for data as needed.
  -- Extend bss if needed.
  -- Redirect binary to start execution in new_code.
  -- Find space for eh_frame
  return $! Elf { elfData       = ELFDATA2LSB
                , elfClass      = elf_class
                , elfOSABI      = elfOSABI orig_binary
                , elfABIVersion = 0
                , elfType       = ET_EXEC
                , elfMachine    = EM_X86_64
                , elfEntry      = elfEntry orig_binary
                , elfFlags      = 0
                , _elfFileData  = Seq.fromList $
                   [ ElfDataSegment exec_seg
                   ]
                   ++ new_data_segs
                   ++ orig_binary_regions
                   ++ [ ElfDataSectionNameTable
                      , ElfDataSectionHeaders
                      ]
                , elfRelroRange = Nothing
                }