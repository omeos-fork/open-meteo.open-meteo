import Foundation
import SwiftPFor2D
import Vapor
import SwiftNetCDF

#if ENABLE_PARQUET
import SwiftArrowParquet
#endif


/**
 Export a dataset to NetCDF. `Time` is the column major orientation. Use the following command to transpose a NetCDF file
 `brew install nco`
 `ncpdq -O -a time,LAT,LON test.nc test2.nc`
 To remove compression and chunks `ncpdq -O --cnk_plc=unchunk -L 0 -a time,LAT,LON wind_gust_normals.nc wind_gust_normals_transposed.nc`
 
 TODO:
 - Export of derived variables using solar radiation are not yet supported
 - Support arbitrary resampling to other grids
 */
struct ExportCommand: AsyncCommandFix {
    var help: String {
        return "Export to dataset to NetCDF"
    }
    
    struct Signature: CommandSignature {
        @Argument(name: "domains", help: "Model domain")
        var domain: String
        
        @Argument(name: "variable", help: "Weather variable")
        var variable: String
        
        @Option(name: "regridding", help: "Regrid data to a specified grid, perform bias and elevation correction")
        var regriddingDomain: String?
        
        @Option(name: "start_date")
        var startDate: String?
        
        @Option(name: "end_date")
        var endDate: String?
        
        @Option(name: "calculate_daily_normals_over_n_years")
        var dailyNormalsOverNYears: Int?
        
        @Option(name: "normals_years")
        var normalsYears: String?
        
        @Option(name: "normals_width")
        var normalsWith: Int?
        
        @Option(name: "format")
        var format: String?
        
        @Option(name: "rain-day-distribution")
        var rainDayDistribution: String?
        
        @Option(name: "output", short: "o", help: "Output file name. Default: ./output.nc")
        var outputFilename: String?
        
        @Option(name: "compression", short: "c", help: "Enable NetCDF compression and set the compression level from 0-9")
        var compressionLevel: Int?
        
        @Flag(name: "output_coordinates", help: "Output grid coordinates in NetCDF file")
        var outputCoordinates: Bool
        
        @Flag(name: "output_elevation", help: "Output grid elevation in NetCDF file")
        var outputElevation: Bool
        
        /// Get time range from parameters
        func getTime(dtSeconds: Int) throws -> TimerangeDt? {
            guard let startDate, let endDate else {
                return nil
            }
            let start = try IsoDate(fromIsoString: startDate).toTimestamp()
            let end = try IsoDate(fromIsoString: endDate).toTimestamp()
            return TimerangeDt(start: start, to: end.add(dtSeconds), dtSeconds: dtSeconds)
        }
    }
    
    func run(using context: CommandContext, signature: Signature) async throws {
        let logger = context.application.logger
        let domain = try ExportDomain.load(rawValue: signature.domain)
        let regriddingDomain = try TargetGridDomain.load(rawValueOptional: signature.regriddingDomain)
        let format = try ExportFormat.load(rawValueOptional: signature.format) ?? .netcdf
        
        let filePath = signature.outputFilename ?? (format == .netcdf ? "./output.nc" : "./output.parquet")
        
        /*let om = try OmFileReader(file: "/Volumes/2TB_1GBs/data/master-MRI_AGCM3_2_S/temperature_2m_max_linear_bias_seasonal.om")
        
        let data = try om.readAll()
        let grid2 = Cmip6Domain.MRI_AGCM3_2_S.grid
        
        let ncFile = try NetCDF.create(path: filePath, overwriteExisting: true)
        try ncFile.setAttribute("TITLE", "\(domain) aa")
        
        var ncVariable = try ncFile.createVariable(name: "data", type: Float.self, dimensions: [
            try ncFile.createDimension(name: "LAT", length: grid2.ny),
            try ncFile.createDimension(name: "LON", length: grid2.nx),
            try ncFile.createDimension(name: "time", length: 6)
        ])
        try ncVariable.write(data)
        return*/
        
        guard let time = try signature.getTime(dtSeconds: domain.genericDomain.dtSeconds) else {
            fatalError("start_date and end_date must be specified")
        }
        logger.info("Exporing variable \(signature.variable) for dataset \(domain) to file '\(filePath)'")
        
        switch format {
        case .netcdf:
            try generateNetCdf(
                logger: logger,
                file: "\(filePath)~",
                domain: domain,
                variable: signature.variable,
                time: time,
                compressionLevel: signature.compressionLevel,
                targetGridDomain: regriddingDomain,
                outputCoordinates: signature.outputCoordinates,
                outputElevation: signature.outputElevation,
                normals: signature.normalsYears.map { ($0.split(separator: ",").map({Int($0)! }), signature.normalsWith ?? 10) },
                rainDayDistribution: DailyNormalsCalculator.RainDayDistribution.load(rawValueOptional: signature.rainDayDistribution)
            )
            try FileManager.default.moveFileOverwrite(from: "\(filePath)~", to: filePath)
        case .parquet:
            try generateNetCdf(
                logger: logger,
                file: filePath,
                domain: domain,
                variable: signature.variable,
                time: time,
                compressionLevel: signature.compressionLevel,
                targetGridDomain: regriddingDomain,
                outputCoordinates: signature.outputCoordinates,
                outputElevation: signature.outputElevation,
                normals: signature.normalsYears.map { ($0.split(separator: ",").map({Int($0)! }), signature.normalsWith ?? 10) },
                rainDayDistribution: DailyNormalsCalculator.RainDayDistribution.load(rawValueOptional: signature.rainDayDistribution)
            )
        }
    }
    
    func generateParquet(logger: Logger, file: String, domain: ExportDomain, variable: String, time: TimerangeDt, compressionLevel: Int?, targetGridDomain: TargetGridDomain?, outputCoordinates: Bool, outputElevation: Bool, normals: (years: [Int], width: Int)?, rainDayDistribution: DailyNormalsCalculator.RainDayDistribution?) throws {
        #if ENABLE_PARQUET
        
        fatalError("Parquet export not yet implemented")
        
        #else
        fatalError("Apache Parquet support not enabled")
        #endif
        
    }
    
    func generateNetCdf(logger: Logger, file: String, domain: ExportDomain, variable: String, time: TimerangeDt, compressionLevel: Int?, targetGridDomain: TargetGridDomain?, outputCoordinates: Bool, outputElevation: Bool, normals: (years: [Int], width: Int)?, rainDayDistribution: DailyNormalsCalculator.RainDayDistribution?) throws {
        let grid = targetGridDomain?.genericDomain.grid ?? domain.grid
        
        /// needs to be evenly dividable by grid.nx
        //let nLocationChunk = grid.nx / ((18...1).first(where: { grid.nx % $0 == 0 }) ?? 1)
        
        logger.info("Grid nx=\(grid.nx) ny=\(grid.ny) nTime=\(time.count) (\(time.prettyString()))")
        let ncFile = try NetCDF.create(path: file, overwriteExisting: true)
        try ncFile.setAttribute("TITLE", "\(domain) \(variable)")
        let latDimension = try ncFile.createDimension(name: "LAT", length: grid.ny)
        let lonDimension = try ncFile.createDimension(name: "LON", length: grid.nx)

        if outputCoordinates {
            logger.info("Writing coordinates")
            var ncLat = try ncFile.createVariable(name: "latitude", type: Float.self, dimensions: [latDimension])
            var ncLon = try ncFile.createVariable(name: "longitude", type: Float.self, dimensions: [lonDimension])
            try ncLat.write((0..<grid.ny).map{ grid.getCoordinates(gridpoint: $0 * grid.nx).latitude })
            try ncLon.write((0..<grid.nx).map{ grid.getCoordinates(gridpoint: $0).longitude })
        }

        
        if outputElevation {
            logger.info("Writing elevation information")
            var ncElevation = try ncFile.createVariable(name: "elevation", type: Float.self, dimensions: [latDimension, lonDimension])
            let targetDomain = targetGridDomain?.genericDomain ?? domain.genericDomain
            guard let elevationFile = targetDomain.getStaticFile(type: .elevation) else {
                fatalError("Could not read elevation file for domain \(targetDomain)")
            }
            try ncElevation.write(elevationFile.readAll())
        }
        
        // Calculate daily normals
        if let normals {
            let variablesPrecipitation = ["precipitation_sum", "snowfall_water_equivalent_sum"]
            
            let progress = TransferAmountTracker(logger: logger, totalSize: grid.count * time.count * 4, name: "Processed")
            let normalsCalculator = DailyNormalsCalculator(years: normals.years, normalsWidthInYears: normals.width)
            let nTimeNormals = normalsCalculator.timeBins.count * 365
            let timeDimension = try ncFile.createDimension(name: "time", length: nTimeNormals)
            var ncVariable = try ncFile.createVariable(name: "data", type: Float.self, dimensions: [latDimension, lonDimension, timeDimension])
            if let compressionLevel, compressionLevel > 0 {
                try ncVariable.defineDeflate(enable: true, level: compressionLevel, shuffle: true)
                try ncVariable.defineChunking(chunking: .chunked, chunks: [1, 1, nTimeNormals])
            }
            
            logger.info("Calculating daily normals. years=\(normals.years) width=\(normals.width) years. Total raw size \((grid.count * nTimeNormals * 4).bytesHumanReadable)")
            
            if let targetGridDomain {
                let targetDomain = targetGridDomain.genericDomain
                guard let elevationFile = targetDomain.getStaticFile(type: .elevation) else {
                    fatalError("Could not read elevation file for domain \(targetDomain)")
                }
                for l in 0..<grid.count {
                    let coords = grid.getCoordinates(gridpoint: l)
                    let elevation = try grid.readElevation(gridpoint: l, elevationFile: elevationFile)
                    
                    // Read data
                    let reader = try domain.getReader(targetGridDomain: targetGridDomain, lat: coords.latitude, lon: coords.longitude, elevation: elevation.numeric, mode: .land)
                    guard let data = try reader.get(mixed: variable, time: time) else {
                        fatalError("Invalid variable \(variable)")
                    }
                    let normals = variablesPrecipitation.contains(variable) ? normalsCalculator.calculateDailyNormalsPreserveDryDays(values: ArraySlice(data.data), time: time, rainDayDistribution: rainDayDistribution ?? .end) : normalsCalculator.calculateDailyNormals(values: ArraySlice(data.data), time: time)
                    try ncVariable.write(normals, offset: [l/grid.nx, l % grid.nx, 0], count: [1, 1, normals.count])
                    progress.add(time.count * 4)
                }
                progress.finish()
                return
            }
            // Loop over locations, read and write
            for gridpoint in 0..<grid.count {
                // Read data
                let reader = try domain.getReader(position: gridpoint)
                guard let data = try reader.get(mixed: variable, time: time)?.data else {
                    fatalError("Invalid variable \(variable)")
                }
                let normals = variablesPrecipitation.contains(variable) ? normalsCalculator.calculateDailyNormalsPreserveDryDays(values: ArraySlice(data), time: time, rainDayDistribution: rainDayDistribution ?? .end) : normalsCalculator.calculateDailyNormals(values: ArraySlice(data), time: time)
                try ncVariable.write(normals, offset: [gridpoint/grid.nx, gridpoint % grid.nx, 0], count: [1, 1, normals.count])
                progress.add(time.count * 4)
            }
            progress.finish()
            return
        }
        
        let timeDimension = try ncFile.createDimension(name: "time", length: time.count)
        var ncVariable = try ncFile.createVariable(name: "data", type: Float.self, dimensions: [latDimension, lonDimension, timeDimension])
        
        if let compressionLevel, compressionLevel > 0 {
            try ncVariable.defineDeflate(enable: true, level: compressionLevel, shuffle: true)
            try ncVariable.defineChunking(chunking: .chunked, chunks: [1, 1, time.count])
        }
        
        logger.info("Writing data. Total raw size \((grid.count * time.count * 4).bytesHumanReadable)")
        let progress = TransferAmountTracker(logger: logger, totalSize: grid.count * time.count * 4, name: "Processed")
        
        /// Interpolate data from one grid to another and perform bias correction
        if let targetGridDomain {
            let targetDomain = targetGridDomain.genericDomain
            guard let elevationFile = targetDomain.getStaticFile(type: .elevation) else {
                fatalError("Could not read elevation file for domain \(targetDomain)")
            }
            
            for l in 0..<grid.count {
                let coords = grid.getCoordinates(gridpoint: l)
                let elevation = try grid.readElevation(gridpoint: l, elevationFile: elevationFile)
                
                // Read data
                let reader = try domain.getReader(targetGridDomain: targetGridDomain, lat: coords.latitude, lon: coords.longitude, elevation: elevation.numeric, mode: .land)
                guard let data = try reader.get(mixed: variable, time: time) else {
                    fatalError("Invalid variable \(variable)")
                }
                try ncVariable.write(data.data, offset: [l/grid.nx, l % grid.nx, 0], count: [1, 1, time.count])
                progress.add(time.count * 4)
            }
            progress.finish()
            return
        }
        
        // Loop over locations, read and write
        for gridpoint in 0..<grid.count {
            // Read data
            let reader = try domain.getReader(position: gridpoint)
            guard let data = try reader.get(mixed: variable, time: time) else {
                fatalError("Invalid variable \(variable)")
            }
            try ncVariable.write(data.data, offset: [gridpoint/grid.nx, gridpoint % grid.nx, 0], count: [1, 1, time.count])
            progress.add(time.count * 4)
        }
        
        progress.finish()
    }
}

/// Calculate daily normals. Combine 5 days to have some sort of statistical significance.
struct DailyNormalsCalculator {
    /// Timerange of individual ranges that may overlap. E.g.  `2025-2034`, `2030-2039`, `2035-2044`, `2040-2049`
    let timeBins: [Range<Timestamp>]
    
    /// Create normals over a given timespan
    init(years: [Int], normalsWidthInYears: Int) {
        timeBins = years.map { year in
            // in case 5 years with, use the year 2022 as center and form 2020-2024 normals
            Timestamp(year - normalsWidthInYears / 2, 1, 1) ..< Timestamp(year + normalsWidthInYears / 2 + normalsWidthInYears % 2, 1, 1)
        }
    }
    
    /// Calculate mean daily normals
    /// Total `time` of entire data series... e.g. `2025-2049`
    func calculateDailyNormals(values: ArraySlice<Float>, time: TimerangeDt) -> [Float] {
        let nBins = timeBins.count
        var sum = [Float](repeating: 0, count: nBins * 365)
        var count = [Float](repeating: 0, count: nBins * 365)
        for (t, value) in zip(time, values) {
            for (bin, binTime) in timeBins.enumerated() {
                guard binTime.contains(t) else {
                    continue
                }
                for i in -2...2 {
                    /// 0-364
                    let dayOfYear = Int(Float(t.add(days: i).timeIntervalSince1970 / 86400).truncatingRemainder(dividingBy: 365.25)) % 365
                    sum[bin * 365 + dayOfYear] += value
                    count[bin * 365 + dayOfYear] += 1
                }
            }
        }
        for i in sum.indices {
            sum[i] /= count[i]
        }
        return sum
    }
    
    
    enum RainDayDistribution: String, CaseIterable {
        /// Place all rainy days at the beginning of each week
        case end
        
        /// Distribute rainy days throughout the week
        case mixed
    }
    
    /// Calculate daily mean values, but preserve events below a certain threshold. E.g. for precipitation. Approach:
    /// - Split a year into 52 parts (each 7 days long)
    /// - For each "part" calculate sum, count and the number below a threshold
    /// - Also distribute each "value" into 5 parts to reduce outliners. Effectivly calcualting 35 days sliding values
    /// - To restore daily normals, calculate the average for each part and distribute according to "days below threshold"
    /// - Days below threhold (dry days) will be at the beginning of each 11-day part
    ///
    /// Total `time` of entire data series... e.g. `2025-2049`
    func calculateDailyNormalsPreserveDryDays(values: ArraySlice<Float>, time: TimerangeDt, lowerThanThreshold: Float = 0.3, rainDayDistribution: RainDayDistribution) -> [Float] {
        let nBins = timeBins.count
        
        /// Number of parts to split a year into. 365.25 / 52 = ~7.02 days
        let partPerYear = 52
        /// Sum of all values
        var partsSum = [Float](repeating: 0, count: nBins * partPerYear)
        /// Sum of all events where value is below threshold
        var partsEvents = [Float](repeating: 0, count: nBins * partPerYear)
        /// Number of values accumulated for this part
        var partsCount = [Float](repeating: 0, count: nBins * partPerYear)
        /// Number of seconds in e.g. ~7 days
        let secondsPerPart = Timestamp.secondsPerAverageYear / partPerYear
        
        // Calculate statistics for each part
        for (t, value) in zip(time, values) {
            for (bin, binTime) in timeBins.enumerated() {
                guard binTime.contains(t) else {
                    continue
                }
                let partIndex = (t.timeIntervalSince1970 / secondsPerPart) % partPerYear
                // Distribute the value also to the previous and next bin
                for i in -2...2 {
                    partsSum[bin * partPerYear + ((partIndex+i) % partPerYear)] += value
                    partsCount[bin * partPerYear + ((partIndex+i) % partPerYear)] += 1
                    if value < lowerThanThreshold {
                        partsEvents[bin * partPerYear + ((partIndex+i) % partPerYear)] += 1
                    }
                }
            }
        }
        // Restore 365 daily normals. The first days of a part will always be "dry days"
        return (0..<365*nBins).map { i in
            let daysPerPart = 365 / partPerYear
            let yearIndex = i / 365
            let partIndex = min((i % 365) / daysPerPart, partPerYear-1)
            let index = yearIndex * partPerYear + partIndex
            let fractionBelowThreshold = partsEvents[index] / partsSum[index]
            let dryDays = Int(round(fractionBelowThreshold * Float(daysPerPart)))
            let wetDays = max(daysPerPart - dryDays, 1)
            let dayOfPart = i % daysPerPart
            switch rainDayDistribution {
            case .end:
                if dayOfPart < dryDays {
                    return 0
                }
            case .mixed:
                let rainDayPositions: [Int]
                switch wetDays {
                case 1:
                    rainDayPositions = [3]
                case 2:
                    rainDayPositions = [1, 4]
                case 3:
                    rainDayPositions = [1, 3, 5]
                case 4:
                    rainDayPositions = [0, 2, 4, 6]
                case 5:
                    rainDayPositions = [0, 2, 4, 5, 6]
                case 6:
                    rainDayPositions = [0, 1, 2, 4, 5, 6]
                case 7:
                    rainDayPositions = [0, 1, 2, 3, 4, 5, 6]
                default:
                    fatalError("Not reachable")
                }
                if !rainDayPositions.contains(dayOfPart) {
                    return 0
                }
            }
            return partsSum[index] / partsCount[index] / (Float(wetDays) / Float(daysPerPart))
        }
    }
}


enum TargetGridDomain: String, CaseIterable {
    /// interpolates weights to 10 km, uses elevation information from era5 land
    case era5_interpolated_10km
    case era5_land
    case imerg
    
    var genericDomain: GenericDomain {
        switch self {
        case .era5_interpolated_10km:
            fallthrough
        case .era5_land:
            return CdsDomain.era5_land
        case .imerg:
            return SatelliteDomain.imerg_daily
        }
    }
}

enum ExportFormat: String, RawRepresentableString, CaseIterable {
    case netcdf
    case parquet
}

enum ExportDomain: String, CaseIterable {
    case CMCC_CM2_VHR4
    case FGOALS_f3_H
    case HiRAM_SIT_HR
    case MRI_AGCM3_2_S
    case EC_Earth3P_HR
    case MPI_ESM1_2_XR
    case NICAM16_8S
    case glofas_v3_consolidated
    case glofas_v4_consolidated
    case glofas_v3_forecast
    case glofas_v3_seasonal
    case era5_land
    case era5
    
    var genericDomain: GenericDomain {
        switch self {
        case .CMCC_CM2_VHR4:
            return Cmip6Domain.CMCC_CM2_VHR4
        case .MRI_AGCM3_2_S:
            return Cmip6Domain.MRI_AGCM3_2_S
        case .FGOALS_f3_H:
            return Cmip6Domain.FGOALS_f3_H
        case .HiRAM_SIT_HR:
            return Cmip6Domain.HiRAM_SIT_HR
        case .EC_Earth3P_HR:
            return Cmip6Domain.EC_Earth3P_HR
        case .MPI_ESM1_2_XR:
            return Cmip6Domain.MPI_ESM1_2_XR
        case .NICAM16_8S:
            return Cmip6Domain.NICAM16_8S
        case .glofas_v3_consolidated:
            return GloFasDomain.consolidatedv3
        case .glofas_v4_consolidated:
            return GloFasDomain.consolidated
        case .glofas_v3_forecast:
            return GloFasDomain.forecastv3
        case .glofas_v3_seasonal:
            return GloFasDomain.seasonalv3
        case .era5_land:
            return CdsDomain.era5_land
        case .era5:
            return CdsDomain.era5
        }
    }
    
    var cmipDomain: Cmip6Domain? {
        switch self {
        case .CMCC_CM2_VHR4:
            return Cmip6Domain.CMCC_CM2_VHR4
        case .MRI_AGCM3_2_S:
            return Cmip6Domain.MRI_AGCM3_2_S
        case .FGOALS_f3_H:
            return Cmip6Domain.FGOALS_f3_H
        case .HiRAM_SIT_HR:
            return Cmip6Domain.HiRAM_SIT_HR
        case .EC_Earth3P_HR:
            return Cmip6Domain.EC_Earth3P_HR
        case .MPI_ESM1_2_XR:
            return Cmip6Domain.MPI_ESM1_2_XR
        case .NICAM16_8S:
            return Cmip6Domain.NICAM16_8S
        case .glofas_v3_consolidated:
            return nil
        case .glofas_v4_consolidated:
            return nil
        case .glofas_v3_forecast:
            return nil
        case .glofas_v3_seasonal:
            return nil
        case .era5_land:
            return nil
        case .era5:
            return nil
        }
    }
    
    var grid: Gridable {
        return genericDomain.grid
    }
    
    func getReader(position: Int) throws -> any GenericReaderProtocol {
        switch self {
        case .CMCC_CM2_VHR4:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.CMCC_CM2_VHR4, position: position), domain: Cmip6Domain.CMCC_CM2_VHR4), domain: Cmip6Domain.CMCC_CM2_VHR4)
        case .MRI_AGCM3_2_S:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.MRI_AGCM3_2_S, position: position), domain: .MRI_AGCM3_2_S), domain: .MRI_AGCM3_2_S)
        case .FGOALS_f3_H:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.FGOALS_f3_H, position: position), domain: .FGOALS_f3_H), domain: .FGOALS_f3_H)
        case .HiRAM_SIT_HR:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.HiRAM_SIT_HR, position: position), domain: .HiRAM_SIT_HR), domain: .HiRAM_SIT_HR)
        case .EC_Earth3P_HR:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.EC_Earth3P_HR, position: position), domain: .EC_Earth3P_HR), domain: .EC_Earth3P_HR)
        case .MPI_ESM1_2_XR:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.MPI_ESM1_2_XR, position: position), domain: .MPI_ESM1_2_XR), domain: .MPI_ESM1_2_XR)
        case .NICAM16_8S:
            return Cmip6ReaderPostBiasCorrected(reader: Cmip6ReaderPreBiasCorrection(reader: try GenericReader(domain: Cmip6Domain.NICAM16_8S, position: position), domain: .NICAM16_8S), domain: .NICAM16_8S)
        case .glofas_v3_consolidated:
            return try GenericReader<GloFasDomain, GloFasVariable>(domain: GloFasDomain.consolidatedv3, position: position)
        case .glofas_v4_consolidated:
            return try GenericReader<GloFasDomain, GloFasVariable>(domain: GloFasDomain.consolidated, position: position)
        case .glofas_v3_forecast:
            return try GenericReader<GloFasDomain, GloFasVariable>(domain: GloFasDomain.forecastv3, position: position)
        case .glofas_v3_seasonal:
            return try GenericReader<GloFasDomain, GloFasVariableMember>(domain: GloFasDomain.seasonalv3, position: position)
        case .era5_land:
            return Era5Reader(reader: GenericReaderCached<CdsDomain, Era5Variable>(reader: try GenericReader<CdsDomain, Era5Variable>(domain: .era5_land, position: position)))
        case .era5:
            return Era5Reader(reader: GenericReaderCached<CdsDomain, Era5Variable>(reader: try GenericReader<CdsDomain, Era5Variable>(domain: .era5, position: position)))
        }
    }
    
    func getReader(targetGridDomain: TargetGridDomain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode) throws -> any GenericReaderProtocol {

        guard let cmipDomain = self.cmipDomain else {
            fatalError("Regridding only supported for CMIP domains")
        }
        switch targetGridDomain {
        case .era5_interpolated_10km:
            guard let biasCorrector = try Cmip6BiasCorrectorInterpolatedWeights(domain: cmipDomain, referenceDomain: CdsDomain.era5, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
                throw ForecastapiError.noDataAvilableForThisLocation
            }
            return biasCorrector
        case .era5_land:
            guard let biasCorrector = try Cmip6BiasCorrectorEra5Seamless(domain: cmipDomain, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
                throw ForecastapiError.noDataAvilableForThisLocation
            }
            return biasCorrector
        case .imerg:
            guard let biasCorrector = try Cmip6BiasCorrectorGenericDomain(domain: cmipDomain, referenceDomain: SatelliteDomain.imerg_daily, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
                throw ForecastapiError.noDataAvilableForThisLocation
            }
            return biasCorrector
        }
    }
}
