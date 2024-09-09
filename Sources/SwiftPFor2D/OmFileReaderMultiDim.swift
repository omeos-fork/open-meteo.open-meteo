//
//  File.swift
//  
//
//  Created by Patrick Zippenfenig on 09.09.2024.
//

import Foundation
@_implementationOnly import CTurboPFor
@_implementationOnly import CHelper


public final class OmFileReader2<Backend: OmFileReaderBackend> {
    public let fn: Backend
    
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// Number of elements in dimension 0... The slow one
    public let dim0: Int
    
    /// Number of elements in dimension 1... The fast one. E.g. time-series
    public let dim1: Int
    
    /// Number of elements in dimension 0... The slow one
    public let dim2: Int
    
    /// Number of elements in dimension 1... The fast one. E.g. time-series
    public let dim3: Int
    
    /// Number of elements to chunk in dimension 0. Must be lower or equals `chunk0`
    public let chunk0: Int
    
    /// Number of elements to chunk in dimension 1. Must be lower or equals `chunk1`
    public let chunk1: Int
    
    
    /// Number of elements to chunk in dimension 0. Must be lower or equals `chunk0`
    public let chunk2: Int
    
    /// Number of elements to chunk in dimension 1. Must be lower or equals `chunk1`
    public let chunk3: Int
    
    
    public init(fn: Backend) throws {
        // Fetch header
        fn.preRead(offset: 0, count: OmHeader.length)
        let header = fn.withUnsafeBytes {
            $0.baseAddress!.withMemoryRebound(to: OmHeader.self, capacity: 1) { ptr in
                ptr.pointee
            }
        }
        
        guard header.magicNumber1 == OmHeader.magicNumber1 && header.magicNumber2 == OmHeader.magicNumber2 else {
            throw SwiftPFor2DError.notAOmFile
        }
        
        self.fn = fn
        dim0 = header.dim0
        dim1 = header.dim1
        chunk0 = header.chunk0
        chunk1 = header.chunk1
        dim2 = header.dim0
        dim3 = header.dim1
        chunk2 = header.chunk0
        chunk3 = header.chunk1
        scalefactor = header.scalefactor
        // bug in version 1: compression type was random
        compression = header.version == 1 ? .p4nzdec256 : CompressionType(rawValue: header.compression)!
    }
    
    /// Prefetch fhe required data regions into memory
    public func willNeed(dim0Slow dim0Read: Range<Int>? = nil, dim1 dim1Read: Range<Int>? = nil) throws {
        guard fn.needsPrefetch else {
            return
        }
        let dim0Read = dim0Read ?? 0..<dim0
        let dim1Read = dim1Read ?? 0..<dim1
        
        guard dim0Read.lowerBound >= 0 && dim0Read.lowerBound <= dim0 && dim0Read.upperBound <= dim0 else {
            throw SwiftPFor2DError.dimensionOutOfBounds(range: dim0Read, allowed: dim0)
        }
        guard dim1Read.lowerBound >= 0 && dim1Read.lowerBound <= dim1 && dim1Read.upperBound <= dim1 else {
            throw SwiftPFor2DError.dimensionOutOfBounds(range: dim1Read, allowed: dim1)
        }
        
        let nDim0Chunks = dim0.divideRoundedUp(divisor: chunk0)
        let nDim1Chunks = dim1.divideRoundedUp(divisor: chunk1)
        
        let nChunks = nDim0Chunks * nDim1Chunks
        var fetchStart = 0
        var fetchEnd = 0
        fn.withUnsafeBytes { ptr in
            let chunkOffsets = ptr.assumingMemoryBound(to: UInt8.self).baseAddress!.advanced(by: OmHeader.length).assumingMemoryBound(to: Int.self, capacity: nChunks)
            
            let compressedDataStartOffset = OmHeader.length + nChunks * MemoryLayout<Int>.stride
            
            for c0 in dim0Read.divide(by: chunk0) {
                let c1Range = dim1Read.divide(by: chunk1)
                let c1Chunks = c1Range.add(c0 * nDim1Chunks)
                // pre-read chunk table at specific offset
                fn.prefetchData(offset: OmHeader.length + max(c1Chunks.lowerBound - 1, 0) * MemoryLayout<Int>.stride, count: (c1Range.count+1) * MemoryLayout<Int>.stride)
                fn.preRead(offset: OmHeader.length + max(c1Chunks.lowerBound - 1, 0) * MemoryLayout<Int>.stride, count: (c1Range.count+1) * MemoryLayout<Int>.stride)
                
                for c1 in c1Range {
                    // load chunk from mmap
                    let chunkNum = c0 * nDim1Chunks + c1
                    let startPos = chunkNum == 0 ? 0 : chunkOffsets[chunkNum-1]
                    let lengthCompressedBytes = chunkOffsets[chunkNum] - startPos
                    
                    let newfetchStart = compressedDataStartOffset + startPos
                    let newfetchEnd = newfetchStart + lengthCompressedBytes
                    
                    if newfetchStart != fetchEnd {
                        if fetchEnd != 0 {
                            //print("fetching from \(fetchStart) to \(fetchEnd)... count \(fetchEnd-fetchStart)")
                            fn.prefetchData(offset: fetchStart, count: fetchEnd-fetchStart)
                        }
                        fetchStart = newfetchStart
                        
                    }
                    fetchEnd = newfetchEnd
                }
            }
        }
        
        //print("fetching from \(fetchStart) to \(fetchEnd)... count \(fetchEnd-fetchStart)")
        fn.prefetchData(offset: fetchStart, count: fetchEnd-fetchStart)
    }
    
    /// Read data into existing buffers. Can only work with sequential ranges. Reading random offsets, requires external loop.
    ///
    /// This code could be moved to C/Rust for better performance. The 2D delta and scaling code is not yet using vector instructions yet
    /// Future implemtations could use async io via lib uring
    ///
    /// `into` is a 2d flat array with `arrayDim1Length` count elements in the fast dimension
    /// `chunkBuffer` is used to temporary decompress chunks of data
    /// `arrayDim1Range` defines the offset in dimension 1 what is applied to the read into array
    /// `arrayDim1Length` if dim0Slow.count is greater than 1, the arrayDim1Length will be used as a stride. Like `nTime` in a 2d fast time array
    /// `dim0Slow` the slow dimension to read. Typically a location range
    /// `dim1Read` the fast dimension to read. Tpyicall a time range
    public func read(into: UnsafeMutablePointer<Float>, arrayDim1Range: Range<Int>, arrayDim1Length: Int, chunkBuffer: UnsafeMutableRawPointer, dim0Slow dim0Read: Range<Int>, dim1 dim1Read: Range<Int>) throws {
        
        //assert(arrayDim1Range.count == dim1Read.count)
        
        guard dim0Read.lowerBound >= 0 && dim0Read.lowerBound <= dim0 && dim0Read.upperBound <= dim0 else {
            throw SwiftPFor2DError.dimensionOutOfBounds(range: dim0Read, allowed: dim0)
        }
        guard dim1Read.lowerBound >= 0 && dim1Read.lowerBound <= dim1 && dim1Read.upperBound <= dim1 else {
            throw SwiftPFor2DError.dimensionOutOfBounds(range: dim1Read, allowed: dim1)
        }
        let dim2Read = dim1Read
        let dim3Read = dim2Read
        
        let nDim0Chunks = dim0.divideRoundedUp(divisor: chunk0)
        let nDim1Chunks = dim1.divideRoundedUp(divisor: chunk1)
        let nDim2Chunks = dim2.divideRoundedUp(divisor: chunk2)
        let nDim3Chunks = dim3.divideRoundedUp(divisor: chunk3)
        
        let nChunks = nDim0Chunks * nDim1Chunks
        fn.withUnsafeBytes { ptr in
            //fn.preRead(offset: OmHeader.length, count: nChunks * MemoryLayout<Int>.stride)
            let chunkOffsets = ptr.assumingMemoryBound(to: UInt8.self).baseAddress!.advanced(by: OmHeader.length).assumingMemoryBound(to: Int.self, capacity: nChunks)
            
            let compressedDataStartOffset = OmHeader.length + nChunks * MemoryLayout<Int>.stride
            let compressedDataStartPtr = UnsafeMutablePointer(mutating: ptr.assumingMemoryBound(to: UInt8.self).baseAddress!.advanced(by: compressedDataStartOffset))
            
            switch compression {
            case.p4nzdec256logarithmic:
                fallthrough
            case .p4nzdec256:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Int16.self)
                for c0 in dim0Read.divide(by: chunk0) {
                   
                    //let c1Chunks = c1Range.add(c0 * nDim1Chunks)
                    // pre-read chunk table at specific offset
                    //fn.preRead(offset: OmHeader.length + max(c1Chunks.lowerBound - 1, 0) * MemoryLayout<Int>.stride, count: (c1Range.count+1) * MemoryLayout<Int>.stride)
                    for c1 in dim1Read.divide(by: chunk1) {
                        for c2 in dim2Read.divide(by: chunk2) {
                            for c3 in dim3Read.divide(by: chunk3) {
                                // load chunk into buffer
                                // consider the length, even if the last is only partial... E.g. at 1000 elements with 600 chunk length, the last one is only 400
                                
                                let length0 = min((c0+1) * chunk0, dim0) - c0 * chunk0
                                let length1 = min((c1+1) * chunk1, dim1) - c1 * chunk1
                                let length2 = min((c2+1) * chunk2, dim2) - c2 * chunk2
                                let length3 = min((c3+1) * chunk3, dim3) - c3 * chunk3
                                
                                /// The chunk coordinates in global space... e.g. 600..<1000
                                let chunkGlobal0 = c0 * chunk0 ..< c0 * chunk0 + length0
                                let chunkGlobal1 = c1 * chunk1 ..< c1 * chunk1 + length1
                                let chunkGlobal2 = c2 * chunk2 ..< c2 * chunk2 + length2
                                let chunkGlobal3 = c3 * chunk3 ..< c3 * chunk3 + length3
                                
                                /// This chunk clamped to read coodinates... e.g. 650..<950
                                let clampedGlobal0 = chunkGlobal0.clamped(to: dim0Read)
                                let clampedGlobal1 = chunkGlobal1.clamped(to: dim1Read)
                                let clampedGlobal2 = chunkGlobal2.clamped(to: dim2Read)
                                let clampedGlobal3 = chunkGlobal3.clamped(to: dim3Read)
                                
                                // load chunk from mmap
                                let chunkNum = ((c0 * nDim1Chunks + c1) * nDim2Chunks + c2) * nDim3Chunks + c3
                                
                                precondition(chunkNum < nChunks, "invalid chunkNum")
                                let startPos = chunkNum == 0 ? 0 : chunkOffsets[chunkNum-1]
                                precondition(compressedDataStartOffset + startPos < ptr.count, "chunk out of range read")
                                let lengthCompressedBytes = chunkOffsets[chunkNum] - startPos
                                fn.preRead(offset: compressedDataStartOffset + startPos, count: lengthCompressedBytes)
                                let uncompressedBytes = p4nzdec128v16(compressedDataStartPtr.advanced(by: startPos), length0 * length1, chunkBuffer)
                                precondition(uncompressedBytes == lengthCompressedBytes, "chunk read bytes mismatch")
                                
                                // 2D delta decoding
                                delta2d_decode(length0, length1, chunkBuffer)
                                
                                /// Moved to local coordinates... e.g. 50..<350
                                let clampedLocal0 = clampedGlobal0.substract(c0 * chunk0)
                                let clampedLocal1 = clampedGlobal1.lowerBound - c1 * chunk1
                                
                                for d0 in clampedLocal0 {
                                    let readStart = clampedLocal1 + d0 * length1
                                    let localOut0 = chunkGlobal0.lowerBound + d0 - dim0Read.lowerBound
                                    let localOut1 = clampedGlobal1.lowerBound - dim1Read.lowerBound
                                    let localRange = localOut1 + localOut0 * arrayDim1Length + arrayDim1Range.lowerBound
                                    for i in 0..<clampedGlobal1.count {
                                        let posBuffer = readStart + i
                                        let posOut = localRange + i
                                        let val = chunkBuffer[posBuffer]
                                        if val == Int16.max {
                                            into.advanced(by: posOut).pointee = .nan
                                        } else {
                                            let unscaled = compression == .p4nzdec256logarithmic ? (powf(10, Float(val) / scalefactor) - 1) : (Float(val) / scalefactor)
                                            into.advanced(by: posOut).pointee = unscaled
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            case .fpxdec32:
                let chunkBufferUInt = chunkBuffer.assumingMemoryBound(to: UInt32.self)
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Float.self)
                
                for c0 in dim0Read.divide(by: chunk0) {
                    let c1Range = dim1Read.divide(by: chunk1)
                    let c1Chunks = c1Range.add(c0 * nDim1Chunks)
                    // pre-read chunk table at specific offset
                    fn.preRead(offset: OmHeader.length + max(c1Chunks.lowerBound - 1, 0) * MemoryLayout<Int>.stride, count: (c1Range.count+1) * MemoryLayout<Int>.stride)
                    
                    for c1 in c1Range {
                        // load chunk into buffer
                        // consider the length, even if the last is only partial... E.g. at 1000 elements with 600 chunk length, the last one is only 400
                        let length1 = min((c1+1) * chunk1, dim1) - c1 * chunk1
                        let length0 = min((c0+1) * chunk0, dim0) - c0 * chunk0
                        
                        /// The chunk coordinates in global space... e.g. 600..<1000
                        let chunkGlobal0 = c0 * chunk0 ..< c0 * chunk0 + length0
                        let chunkGlobal1 = c1 * chunk1 ..< c1 * chunk1 + length1
                        
                        /// This chunk clamped to read coodinates... e.g. 650..<950
                        let clampedGlobal0 = chunkGlobal0.clamped(to: dim0Read)
                        let clampedGlobal1 = chunkGlobal1.clamped(to: dim1Read)
                        
                        // load chunk from mmap
                        let chunkNum = c0 * nDim1Chunks + c1
                        let startPos = chunkNum == 0 ? 0 : chunkOffsets[chunkNum-1]
                        let lengthCompressedBytes = chunkOffsets[chunkNum] - startPos
                        fn.preRead(offset: compressedDataStartOffset + startPos, count: lengthCompressedBytes)
                        let uncompressedBytes = fpxdec32(compressedDataStartPtr.advanced(by: startPos), length0 * length1, chunkBufferUInt, 0)
                        precondition(uncompressedBytes == lengthCompressedBytes)
                        
                        // 2D xor decoding
                        delta2d_decode_xor(length0, length1, chunkBuffer)
                        
                        /// Moved to local coordinates... e.g. 50..<350
                        let clampedLocal0 = clampedGlobal0.substract(c0 * chunk0)
                        let clampedLocal1 = clampedGlobal1.lowerBound - c1 * chunk1
                        
                        for d0 in clampedLocal0 {
                            let readStart = clampedLocal1 + d0 * length1
                            let localOut0 = chunkGlobal0.lowerBound + d0 - dim0Read.lowerBound
                            let localOut1 = clampedGlobal1.lowerBound - dim1Read.lowerBound
                            let localRange = localOut1 + localOut0 * arrayDim1Length + arrayDim1Range.lowerBound
                            for i in 0..<clampedGlobal1.count {
                                let posBuffer = readStart + i
                                let posOut = localRange + i
                                let val = chunkBuffer[posBuffer]
                                into.advanced(by: posOut).pointee = val
                            }
                        }
                    }
                }
            }
        }
    }
}
