@_implementationOnly import OmFileFormatC
@_implementationOnly import CHelper
import Foundation

/// All data is written to this buffer. It needs to be emptied periodically after writing large chunks of data.
/// TODO consider reallocation strategy when migrating to C
public final class OmFileBufferedWriter {
    /// All data is written to this buffer. The current offset is in `writeBufferPos`. This buffer must be written out before it is full.
    public var buffer: UnsafeMutableBufferPointer<UInt8>
        
    public var writePosition = UInt64(0)
    
    public var totalBytesWritten = UInt64(0)
    
    /// Total capacity
    public let capacity: UInt64
    
    public init(capacity: UInt64) {
        self.writePosition = 0
        self.totalBytesWritten = 0
        self.capacity = capacity
        self.buffer = .allocate(capacity: Int(capacity))
    }
    
    public func writeHeader<FileHandle: OmFileWriterBackend>(fn: FileHandle) throws {
        writeHeader()
        try fn.write(contentsOf: buffer[0..<Int(writePosition)].map({$0}))
        writePosition = 0
    }
    
    public func writeTrailer<FileHandle: OmFileWriterBackend>(meta: OmFileJSON, fn: FileHandle) throws {
        try writeTrailer(meta: meta)
        try fn.write(contentsOf: buffer[0..<Int(writePosition)].map({$0}))
        writePosition = 0
    }
    
    deinit {
        buffer.deallocate()
    }
    
    /// Write header. Only magic number and version 3
    public func writeHeader() {
        assert(capacity - writePosition >= 3)
        buffer[Int(writePosition) + 0] = OmHeader.magicNumber1
        buffer[Int(writePosition) + 1] = OmHeader.magicNumber2
        buffer[Int(writePosition) + 2] = 3
        writePosition += 3
        totalBytesWritten += 3
    }
    
    /// Serialise JSON, write to buffer and write size of JSON
    public func writeTrailer(meta: OmFileJSON) throws {
        //print(meta)
        
        // Serialise and write JSON
        let json = try JSONEncoder().encode(meta)
        assert(capacity - writePosition >= json.count)
        let jsonLength = json.withUnsafeBytes({
            memcpy(buffer.baseAddress!.advanced(by: Int(writePosition)), $0.baseAddress!, $0.count)
            return UInt64($0.count)
        })
        writePosition += jsonLength
        totalBytesWritten += jsonLength
        
        // TODO Pad to 64 bit?
        // TODO Additional version field and maybe some reserved stuff. E.g. if the JSON payload should be compressed later.
        
        // write length of JSON
        assert(capacity - writePosition >= 8)
        buffer.baseAddress!.advanced(by: Int(writePosition)).assumingMemoryBound(to: Int.self, capacity: 1)[0] = Int(jsonLength)
        writePosition += 8
        totalBytesWritten += 8
    }
}

public final class OmFileWriter2 {
    /// Store all byte offsets where our compressed chunks start. Later, we want to decompress chunk 1234 and know it starts at byte offset 5346545
    private var lookUpTable: [UInt64]
    
    let encoder: OmFileEncoder
    
    /// Position of last chunk that has been written
    public var chunkIndex: Int = 0
    
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    // TODO datatype
    
    /// The dimensions of the file
    let dims: [UInt64]
    
    /// How the dimensions are chunked
    let chunks: [UInt64]
    
    /**
     Write new or overwrite new compressed file. Data must be supplied with a closure which supplies the current position in dimension 0. Typically this is the location offset. The closure must return either an even number of elements of `chunk0 * dim1` elements or all remainig elements at once.
     
     One chunk should be around 2'000 to 16'000 elements. Fewer or more are not usefull!
     
     Note: `chunk0` can be a uneven multiple of `dim0`. E.g. for 10 location, we can use chunks of 3, so the last chunk will only cover 1 location.
     */
    public init(dimensions: [UInt64], chunkDimensions: [UInt64], compression: CompressionType, scalefactor: Float, lutChunkElementCount: Int = 256) {
        
        /*let chunkSizeByte = chunkDimensions.reduce(1, *) * 4
        if chunkSizeByte > 1024 * 1024 * 4 {
            print("WARNING: Chunk size greater than 4 MB (\(Float(chunkSizeByte) / 1024 / 1024) MB)!")
        }*/
        
        self.encoder = OmFileEncoder(scalefactor: scalefactor, compression: compression, dims: dimensions, chunks: chunkDimensions, lutChunkElementCount: lutChunkElementCount)
        let nChunks = self.encoder.number_of_chunks()
        
        // +1 to store also the start address
        self.lookUpTable = .init(repeating: 0, count: Int(nChunks + 1))
        self.chunks = chunkDimensions
        self.dims = dimensions
        self.compression = compression
        self.scalefactor = scalefactor
    }
    
    /// Can be all, a single or multiple chunks
    public func writeData<FileHandle: OmFileWriterBackend>(array: [Float], arrayDimensions: [UInt64], arrayRead: [Range<UInt64>], fn: FileHandle, out: OmFileBufferedWriter) throws {
        // TODO check dimensions of arrayDimensions and arrayRead
        
        let arrayOffset = arrayRead.map({UInt64($0.lowerBound)})
        let arrayCount = arrayRead.map({UInt64($0.count)})
        
        var numberOfChunksInArray = UInt64(1)
        for i in 0..<encoder.dims.count {
            numberOfChunksInArray *= UInt64(arrayRead[i].count).divideRoundedUp(divisor: encoder.chunks[i])
        }
        
        let lengthInChunk = encoder.chunks.reduce(1, *)
        let minimumBuffer = P4NENC256_BOUND(n: Int(lengthInChunk), bytesPerElement: 4)
        
        /// TODO encoder func to get buffer size
        let chunkBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: minimumBuffer, alignment: 4)
        defer {
            chunkBuffer.deallocate()
        }
        
        if chunkIndex == 0 {
            // Store data start address
            lookUpTable[chunkIndex] = out.totalBytesWritten
        }
        
        for chunkIndexOffsetInThisArray in 0..<numberOfChunksInArray {
            let outPtr = out.buffer.baseAddress!.advanced(by: Int(out.writePosition))
            let outSize = out.buffer.count - Int(out.writePosition)
            let writeLength = encoder.writeSingleChunk(array: array, arrayDimensions: arrayDimensions, arrayOffset: arrayOffset, arrayCount: arrayCount, chunkIndex: UInt64(chunkIndex), chunkIndexOffsetInThisArray: chunkIndexOffsetInThisArray, out: outPtr, outSize: outSize, chunkBuffer: chunkBuffer)

            //print("compressed size", writeLength, "lengthInChunk", lengthInChunk, "start offset", totalBytesWritten)
            out.writePosition += UInt64(writeLength)
            out.totalBytesWritten += UInt64(writeLength)
            
            // Store chunk offset in LUT
            lookUpTable[chunkIndex+1] = out.totalBytesWritten
            chunkIndex += 1
            
            // Write buffer to disk if the next chunk may not fit anymore in the output buffer
            if out.buffer.count - Int(out.writePosition) <= minimumBuffer {
                try fn.write(contentsOf: out.buffer[0..<Int(out.writePosition)].map({$0}))
                out.writePosition = 0
            }
        }
    }
    
    public func writeLut(out: OmFileBufferedWriter, fn: FileHandle) throws -> UInt64 {
        let lutChunkLength = writeLut(out: out)
        try fn.write(contentsOf: out.buffer[0..<Int(out.writePosition)].map({$0}))
        out.writePosition = 0
        return lutChunkLength
    }
    
    
    /// Returns LUT chunk length
    public func writeLut(out: OmFileBufferedWriter) -> UInt64 {
        let size_of_compressed_lut = encoder.size_of_compressed_lut(lookUpTable: lookUpTable)
        assert(out.buffer.count - Int(out.writePosition) >= Int(size_of_compressed_lut))
        let lutChunkLength = encoder.compress_lut(lookUpTable: lookUpTable, out: out.buffer.baseAddress!.advanced(by: Int(out.writePosition)), size_of_compressed_lut: size_of_compressed_lut)
        out.writePosition += UInt64(size_of_compressed_lut)
        out.totalBytesWritten += UInt64(size_of_compressed_lut)
        return lutChunkLength
    }
    
    func output_buffer_capacity() -> UInt64 {
        encoder.output_buffer_capacity()
    }
}


/// Encodes a single variable to an OpenMeteo file
/// Mutliple variables may be encoded in the single file
///
/// This file currenly allocates a chunk buffer and LUT table. This might change if this is moved to C
struct OmFileEncoder {
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// The dimensions of the file
    let dims: [UInt64]
    
    /// How the dimensions are chunked
    let chunks: [UInt64]

    /// This might be hard coded to 256 in later versions
    let lutChunkElementCount: Int
    
    /// Return the total number of chunks in this file
    func number_of_chunks() -> UInt64 {
        var n = UInt64(1)
        for i in 0..<dims.count {
            n *= dims[i].divideRoundedUp(divisor: chunks[i])
        }
        return n
    }
    
    /// Calculate the size of the output buffer.
    func output_buffer_capacity() -> UInt64 {
        let bufferSize = UInt64(P4NENC256_BOUND(n: Int(chunks.reduce(1, *)), bytesPerElement: compression.bytesPerElement))
        
        var nChunks = UInt64(1)
        for i in 0..<dims.count {
            nChunks *= dims[i].divideRoundedUp(divisor: chunks[i])
        }
        /// Assume the lut buffer is not compressible
        let lutBufferSize = nChunks * 8
        
        return max(4096, max(lutBufferSize, bufferSize))
    }
    
    /// Return the size of the compressed LUT
    func size_of_compressed_lut(lookUpTable: [UInt64]) -> Int {
        /// TODO stack allocate in C
        let bufferSize = P4NENC256_BOUND(n: 256, bytesPerElement: 8)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        
        let nLutChunks = lookUpTable.count.divideRoundedUp(divisor: lutChunkElementCount)
        
        return lookUpTable.withUnsafeBytes({
            var maxLength = 0
            /// Calculate maximum chunk size
            for i in 0..<nLutChunks {
                let rangeStart = i*lutChunkElementCount
                let rangeEnd = min((i+1)*lutChunkElementCount, lookUpTable.count)
                let len = p4ndenc64(UnsafeMutablePointer(mutating: $0.baseAddress?.advanced(by: rangeStart*8).assumingMemoryBound(to: UInt64.self)), rangeEnd-rangeStart, buffer.baseAddress!)
                if len > maxLength { maxLength = len }
            }
            return maxLength * nLutChunks
        })
    }
    
    /// Out size needs to cover at least `size_of_compressed_lut()`
    /// Returns length of each lut chunk
    func compress_lut(lookUpTable: [UInt64], out: UnsafeMutablePointer<UInt8>, size_of_compressed_lut: Int) -> UInt64 {
        let nLutChunks = lookUpTable.count.divideRoundedUp(divisor: lutChunkElementCount)
        let lutChunkLength = size_of_compressed_lut / nLutChunks
        
        lookUpTable.withUnsafeBytes({
            /// Write chunks to buffer and pad all chunks to have `maxLength` bytes
            for i in 0..<nLutChunks {
                let rangeStart = i*lutChunkElementCount
                let rangeEnd = min((i+1)*lutChunkElementCount, lookUpTable.count)
                _ = p4ndenc64(UnsafeMutablePointer(mutating: $0.baseAddress?.advanced(by: rangeStart*8).assumingMemoryBound(to: UInt64.self)), rangeEnd-rangeStart, out.advanced(by: i * lutChunkLength))
            }
        })
        return UInt64(lutChunkLength)
    }
    
    
    /// Write a single chunk
    /// `chunkIndex` is the chunk numer of the global array
    /// `chunkIndexInThisArray` is the chunk index offset, if the current array contains more than one chunk
    /// Return the number of compressed bytes into out
    @inlinable public func writeSingleChunk(array: [Float], arrayDimensions: [UInt64], arrayOffset: [UInt64], arrayCount: [UInt64], chunkIndex: UInt64, chunkIndexOffsetInThisArray: UInt64, out: UnsafeMutablePointer<UInt8>, outSize: Int, chunkBuffer: UnsafeMutableRawBufferPointer) -> Int {
        
        // Calculate number of elements in this chunk
        var rollingMultiplty = UInt64(1)
        var rollingMultiplyChunkLength = UInt64(1)
        var rollingMultiplyTargetCube = UInt64(1)
        
        /// Read coordinate from input array
        var readCoordinate = Int(0)
        
        /// Position to write to in the chunk buffer
        var writeCoordinate = Int(0)
        
        /// Copy multiple elements from the decoded chunk into the output buffer. For long time-series this drastically improves copy performance.
        var linearReadCount = UInt64(1)
        
        /// Internal state to keep track if everything is kept linear
        var linearRead = true
        
        /// Used for 2d delta coding
        var lengthLast = UInt64(0)
        
        /// Count length in chunk and find first buffer offset position
        for i in (0..<dims.count).reversed() {
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            let c0 = (UInt64(chunkIndex) / rollingMultiplty) % nChunksInThisDimension
            let c0Offset = (chunkIndexOffsetInThisArray / rollingMultiplty) % nChunksInThisDimension
            let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
            //let chunkGlobal0 = c0 * chunks[i] ..< c0 * chunks[i] + length0
            //let clampedGlobal0 = chunkGlobal0//.clamped(to: dimRead[i])
            //let clampedLocal0 = clampedGlobal0.substract(c0 * chunks[i])
            
            if i == dims.count-1 {
                lengthLast = length0
            }

            readCoordinate = readCoordinate + Int(rollingMultiplyTargetCube * (c0Offset * chunks[i] + arrayOffset[i]))
            //print("i", i, "arrayRead[i].count", arrayRead[i].count, "length0", length0, "arrayDimensions[i]", arrayDimensions[i])
            assert(length0 <= arrayCount[i])
            assert(length0 <= arrayDimensions[i])
            if i == dims.count-1 && !(arrayCount[i] == length0 && arrayDimensions[i] == length0) {
                // if fast dimension and only partially read
                linearReadCount = length0
                linearRead = false
            }
            if linearRead && arrayCount[i] == length0 && arrayDimensions[i] == length0 {
                // dimension is read entirely
                // and can be copied linearly into the output buffer
                linearReadCount *= length0
            } else {
                // dimension is read partly, cannot merge further reads
                linearRead = false
            }
       
            rollingMultiplty *= nChunksInThisDimension
            rollingMultiplyTargetCube *= arrayDimensions[i]
            rollingMultiplyChunkLength *= length0
        }
        
        /// How many elements are in this chunk
        let lengthInChunk = rollingMultiplyChunkLength
        
        //print("compress chunk \(chunkIndex) lengthInChunk \(lengthInChunk)")
        
        // loop over elements to read and move to target buffer. Apply scalefactor and convert UInt16
        while true {
            //print("q=\(q) d=\(d), count=\(linearReadCount)")
            //linearReadCount = 1
            
            switch compression {
            case .p4nzdec256:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Int16.self)
                for i in 0..<Int(linearReadCount) {
                    assert(readCoordinate+i < array.count)
                    assert(writeCoordinate+i < lengthInChunk)
                    let val = array[readCoordinate+i]
                    if val.isNaN {
                        // Int16.min is not representable because of zigzag coding
                        chunkBuffer[writeCoordinate+i] = Int16.max
                    }
                    let scaled = val * scalefactor
                    chunkBuffer[writeCoordinate+i] = Int16(max(Float(Int16.min), min(Float(Int16.max), round(scaled))))
                }
            case .fpxdec32:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(linearReadCount) {
                    assert(readCoordinate+i < array.count)
                    assert(writeCoordinate+i < lengthInChunk)
                    chunkBuffer[writeCoordinate+i] = array[readCoordinate+i]
                }
            case .p4nzdec256logarithmic:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Int16.self)
                for i in 0..<Int(linearReadCount) {
                    assert(readCoordinate+i < array.count)
                    assert(writeCoordinate+i < lengthInChunk)
                    let val = array[readCoordinate+i]
                    if val.isNaN {
                        // Int16.min is not representable because of zigzag coding
                        chunkBuffer[writeCoordinate+i] = Int16.max
                    }
                    let scaled = log10(1+val) * scalefactor
                    chunkBuffer[writeCoordinate+i] = Int16(max(Float(Int16.min), min(Float(Int16.max), round(scaled))))
                }
            }
            

            readCoordinate += Int(linearReadCount)-1
            writeCoordinate += Int(linearReadCount)-1
            writeCoordinate += 1
            
            // Move `q` to next position
            rollingMultiplyTargetCube = 1
            linearRead = true
            linearReadCount = 1
            for i in (0..<dims.count).reversed() {
                let qPos = ((UInt64(readCoordinate) / rollingMultiplyTargetCube) % arrayDimensions[i] - arrayOffset[i]) / chunks[i]
                let length0 = min((qPos+1) * chunks[i], arrayCount[i]) - qPos * chunks[i]
                
                /// More forward
                readCoordinate += Int(rollingMultiplyTargetCube)
                
                if i == dims.count-1 && !(arrayCount[i] == length0 && arrayDimensions[i] == length0) {
                    // if fast dimension and only partially read
                    linearReadCount = length0
                    linearRead = false
                }
                if linearRead && arrayCount[i] == length0 && arrayDimensions[i] == length0 {
                    // dimension is read entirely
                    // and can be copied linearly into the output buffer
                    linearReadCount *= length0
                } else {
                    // dimension is read partly, cannot merge further reads
                    linearRead = false
                }
                let q0 = ((UInt64(readCoordinate) / rollingMultiplyTargetCube) % arrayDimensions[i] - arrayOffset[i]) % chunks[i]
                if q0 != 0 && q0 != length0 {
                    break // no overflow in this dimension, break
                }
                readCoordinate -= Int(length0 * rollingMultiplyTargetCube)
                
                rollingMultiplyTargetCube *= arrayDimensions[i]
                if i == 0 {
                    // All values have been loaded into chunk buffer. Proceed to compression
                    // 2D coding and compression
                    let writeLength: Int
                    let minimumBuffer: Int
                    switch compression {
                    case .p4nzdec256, .p4nzdec256logarithmic:
                        minimumBuffer = P4NENC256_BOUND(n: Int(lengthInChunk), bytesPerElement: 4)
                        assert(outSize >= minimumBuffer)
                        /// TODO check delta encoding if done correctly
                        delta2d_encode(Int(lengthInChunk / lengthLast), Int(lengthLast), chunkBuffer.assumingMemoryBound(to: Int16.self).baseAddress)
                        writeLength = p4nzenc128v16(chunkBuffer.assumingMemoryBound(to: UInt16.self).baseAddress!, Int(lengthInChunk), out)
                    case .fpxdec32:
                        minimumBuffer = P4NENC256_BOUND(n: Int(lengthInChunk), bytesPerElement: 4)
                        assert(outSize >= minimumBuffer)
                        delta2d_encode_xor(Int(lengthInChunk / lengthLast), Int(lengthLast), chunkBuffer.assumingMemoryBound(to: Float.self).baseAddress)
                        writeLength = fpxenc32(chunkBuffer.assumingMemoryBound(to: UInt32.self).baseAddress!, Int(lengthInChunk), out, 0)
                    }
                    return writeLength
                }
            }
        }
    }
}

