import Combine
import Foundation
import UIKit

private enum AuroraFoodDensityResolver {
    struct Reference {
        let identifier: String
        let aliases: [String]
        let formHints: [String]
        let grams: Double
        let volumeMilliliters: Double
        let sourceDescription: String

        var bulkDensityGramsPerMilliliter: Double {
            grams / volumeMilliliters
        }
    }

    struct Match {
        let identifier: String
        let bulkDensityGramsPerMilliliter: Double
        let referenceDescription: String
        let formMatchCount: Int
    }

    private static let usCupMilliliters = 236.588

    /*
     Density references are deliberately data-driven.

     Important:
     - grams / volumeMilliliters describes BULK density.
     - volume includes void space between loose pieces.
     - different physical forms of the same food may require
       separate Reference entries.
     - only references with defensible household-volume data
       should be added here.
     */
    private static let references: [Reference] = [
        Reference(
            identifier: "walnut_halves_loose",
            aliases: [
                "walnuss",
                "walnüsse",
                "walnut",
                "walnuts"
            ],
            formHints: [
                "hälfte",
                "hälften",
                "half",
                "halves",
                "loose",
                "lose"
            ],
            grams: 100.0,
            volumeMilliliters: usCupMilliliters,
            sourceDescription:
            "100 g per 236.588 ml US cup"
        )
    ]

    static func resolve(
        name: String,
        standardName: String?,
        preparationMethod: String?,
        visualCues: String?
    ) -> Match? {
        let identityText =
            [
                name,
                standardName
            ]
            .compactMap { $0 }
            .map(normalized)
            .joined(separator: " ")

        let formText =
            [
                preparationMethod,
                visualCues
            ]
            .compactMap { $0 }
            .map(normalized)
            .joined(separator: " ")

        let candidates =
            references.compactMap {
                reference -> (
                    reference: Reference,
                    formMatchCount: Int
                )? in

                let aliasMatched =
                    reference.aliases
                        .map(normalized)
                        .contains {
                            identityText.contains($0)
                        }

                guard aliasMatched else {
                    return nil
                }

                let formMatchCount =
                    reference.formHints
                        .map(normalized)
                        .filter {
                            formText.contains($0)
                        }
                        .count

                return (
                    reference: reference,
                    formMatchCount: formMatchCount
                )
            }

        guard let best =
            candidates.max(by: {
                $0.formMatchCount < $1.formMatchCount
            })
        else {
            return nil
        }

        return Match(
            identifier: best.reference.identifier,
            bulkDensityGramsPerMilliliter:
            best.reference
                .bulkDensityGramsPerMilliliter,
            referenceDescription:
            best.reference.sourceDescription,
            formMatchCount:
            best.formMatchCount
        )
    }

    private static func normalized(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .folding(
                options:
                String.CompareOptions.diacriticInsensitive,
                locale:
                Locale(identifier: "en_US_POSIX")
            )
    }
}

class ConfigurableFoodAnalysisService: ObservableObject, @unchecked Sendable {
    static let shared = ConfigurableFoodAnalysisService()

    private init() {}

    var isImageAnalysisConfigured: Bool {
        switch UserDefaults.standard.aiImageProvider {
        case .aiModel(.claude):
            return !UserDefaults.standard.claudeAPIKey.isEmpty
        case .aiModel(.gemini):
            return !UserDefaults.standard.googleGeminiAPIKey.isEmpty
        case .aiModel(.openAI):
            return !UserDefaults.standard.openAIAPIKey.isEmpty
        }
    }

    var isAiTextAnalysisConfigured: Bool {
        switch UserDefaults.standard.aiTextProvider {
        case .aiModel(.claude):
            return !UserDefaults.standard.claudeAPIKey.isEmpty
        case .aiModel(.gemini):
            return !UserDefaults.standard.googleGeminiAPIKey.isEmpty
        case .aiModel(.openAI):
            return !UserDefaults.standard.openAIAPIKey.isEmpty
        }
    }

    var isBarcodeSearchConfigured: Bool {
        switch UserDefaults.standard.barcodeSearchProvider {
        case .openFoodFacts:
            return true
        }
    }

    // MARK: - Public Methods

    func setAPIKey(_ key: String, for provider: AIProvider) {
        switch provider {
        case .claude:
            UserDefaults.standard.claudeAPIKey = key
        case .gemini:
            UserDefaults.standard.googleGeminiAPIKey = key
        case .openAI:
            UserDefaults.standard.openAIAPIKey = key
        }
    }

    func getAPIKey(for provider: AIProvider) -> String? {
        switch provider {
        case .claude:
            let key = UserDefaults.standard.claudeAPIKey
            return key.isEmpty ? nil : key
        case .gemini:
            let key = UserDefaults.standard.googleGeminiAPIKey
            return key.isEmpty ? nil : key
        case .openAI:
            let key = UserDefaults.standard.openAIAPIKey
            return key.isEmpty ? nil : key
        }
    }

    /// Reset to default Basic Analysis provider (useful for troubleshooting)
    func resetToDefault() {
        UserDefaults.standard.aiImageProvider = .defaultProvider
        UserDefaults.standard.textSearchProvider = .defaultProvider
        UserDefaults.standard.barcodeSearchProvider = .defaultProvider
    }

    /// Analyze food image with telemetry callbacks for progress tracking
    func analyzeFoodImage(
        _ images: [UIImage],
        comment: String?,
        telemetryCallback: (@Sendable(String) -> Void)?
    ) async throws -> FoodItemGroup {
        try await analyzeFoodImages(
            images,
            request: .image(images, comment),
            telemetryCallback: telemetryCallback
        )
    }

    func analyzeFoodImage(
        _ captures: [AuroraMealCapture],
        comment: String?,
        telemetryCallback: (@Sendable(String) -> Void)?
    ) async throws -> FoodItemGroup {
        let images = captures.map(\.image)

        return try await analyzeFoodImages(
            images,
            request: .mealCaptures(captures, comment),
            telemetryCallback: telemetryCallback
        )
    }

    private func analyzeFoodImages(
        _ images: [UIImage],
        request: AnalysisRequest,
        telemetryCallback: (@Sendable(String) -> Void)?
    ) async throws -> FoodItemGroup {
        guard !images.isEmpty else {
            throw AIFoodAnalysisError.invalidResponse
        }
        telemetryCallback?("🤖 Connecting to \(UserDefaults.standard.aiImageProvider.description) …")
        let providerImpl = switch UserDefaults.standard.aiImageProvider {
        case let .aiModel(model):
            try getAIImplementation(
                for: model,
                telemetryCallback: telemetryCallback
            )
        }

        let aiModel = switch UserDefaults.standard.aiImageProvider {
        case let .aiModel(model):
            model
        }

        if let stats = AIUsageStatistics.getStatistics(model: aiModel, requestType: .image),
           stats.averageSuccessProcessingTime > 0
        {
            let eta = String(format: "%.1f", stats.averageSuccessProcessingTime)
            telemetryCallback?("ETA: \(eta)")
        } else {
            telemetryCallback?("ETA: \(String(format: "%.0f", aiModel.defaultImageETA))")
        }
        telemetryCallback?("MODEL: \(aiModel.description)")

        telemetryCallback?(
            images.count == 1
                ? "🖼️ Optimizing your image …"
                : "🖼️ Optimizing \(images.count) meal images …"
        )

        var base64Images: [String] = []
        base64Images.reserveCapacity(images.count)

        for image in images {
            let base64Image = try await ImageCompression.getImageBase64(
                for: image,
                maxSize: UserDefaults.standard.shouldSendSmallerImagesToAI ? 1024 : aiModel.maxImageDimension
            )
            base64Images.append(base64Image)
        }

        let analysisPrompt = try AIPrompts.getAnalysisPrompt(
            request,
            responseSchema: AIAnalysisResult.schemaVisual
        )

        let startTime = Date()

        do {
            telemetryCallback?(
                "AURORA MEAL AI: sending \(base64Images.count) image(s) to \(aiModel.description)"
            )

            let result: FoodItemGroup = try await providerImpl.analyzeImage(
                prompt: analysisPrompt,
                images: base64Images,
                telemetryCallback: telemetryCallback
            )

            let adjustedResult: FoodItemGroup = {
                guard case let .mealCaptures(captures, _) = request,
                      let volume =
                      auroraTopViewVolume(from: captures)
                else {
                    return result
                }

                let measuredVolumeML =
                    Double(
                        volume
                            .inner15mmVolume5mmMilliliters
                    )

                guard measuredVolumeML > 0 else {
                    return result
                }

                let adjustedItems =
                    result.foodItems.map { item in
                        guard let density =
                            AuroraFoodDensityResolver.resolve(
                                name: item.name,
                                standardName:
                                item.standardName,
                                preparationMethod:
                                item.preparationMethod,
                                visualCues:
                                item.visualCues
                            )
                        else {
                            return item
                        }

                        guard case let .per100(
                            values,
                            aiPortionSize
                        ) = item.nutrition
                        else {
                            return item
                        }

                        // Do not convert foods whose AI result
                        // explicitly represents a liquid volume.
                        if case .milliliters? = item.units {
                            return item
                        }

                        let calculatedWeight =
                            measuredVolumeML
                                * density
                                .bulkDensityGramsPerMilliliter

                        guard calculatedWeight > 0,
                              calculatedWeight.isFinite
                        else {
                            return item
                        }

                        let calculatedPortion =
                            Decimal(calculatedWeight)

                        let note =
                            String(
                                format:
                                "Aurora LiDAR: %.0f ml; density reference %@; bulk density %.3f g/ml; deterministic portion %.0f g.",
                                measuredVolumeML,
                                density.referenceDescription,
                                density
                                    .bulkDensityGramsPerMilliliter,
                                calculatedWeight
                            )

                        let combinedNotes =
                            [
                                item.assessmentNotes,
                                note
                            ]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")

                        #if DEBUG
                            let aiWeight =
                                NSDecimalNumber(
                                    decimal: aiPortionSize
                                ).doubleValue

                            print(
                                String(
                                    format:
                                    "AURORA DENSITY RESOLVER: food=%@ key=%@ formMatches=%d volume=%.0f ml bulkDensity=%.3f g/ml AuroraWeight=%.0f g AIWeight=%.0f g",
                                    item.name,
                                    density.identifier,
                                    density.formMatchCount,
                                    measuredVolumeML,
                                    density
                                        .bulkDensityGramsPerMilliliter,
                                    calculatedWeight,
                                    aiWeight
                                )
                            )
                        #endif

                        return item.copy(
                            nutrition: .per100(
                                values: values,
                                portionSize:
                                calculatedPortion
                            ),
                            assessmentNotes:
                            combinedNotes
                        )
                    }

                return result.copyWithItems(
                    adjustedItems
                )
            }()

            let processingTime = Date().timeIntervalSince(startTime)
            AIUsageStatistics.recordRequest(
                model: aiModel,
                requestType: .image,
                processingTime: processingTime,
                success: true,
                foodItemCount: adjustedResult.foodItems.count
            )

            return adjustedResult
        } catch {
            let processingTime = Date().timeIntervalSince(startTime)
            AIUsageStatistics.recordRequest(
                model: aiModel,
                requestType: .image,
                processingTime: processingTime,
                success: false
            )
            throw error
        }
    }

    func executeTextSearch(
        _ query: String,
        telemetryCallback: ((String) -> Void)?
    ) async throws -> FoodItemGroup {
        telemetryCallback?("🤖 Connecting to \(UserDefaults.standard.textSearchProvider.description) …")
        switch UserDefaults.standard.textSearchProvider {
        case .usdaFoodData:
            return try await USDAFoodDataService.shared.analyzeText(prompt: query, telemetryCallback: telemetryCallback)
        case .openFoodFacts:
            return try await OpenFoodFactsService.shared.analyzeText(prompt: query, telemetryCallback: telemetryCallback)
        }
    }

    func executeImageSearch(
        _ query: String,
        telemetryCallback: ((String) -> Void)?
    ) async -> [String] {
        let result = try? await OpenFoodFactsService.shared.analyzeText(prompt: query, telemetryCallback: telemetryCallback)
        return result?.foodItems.compactMap(\.imageURL) ?? []
    }

    func analyzeFoodQuery(
        _ query: String,
        telemetryCallback: (@Sendable(String) -> Void)?
    ) async throws -> FoodItemGroup {
        telemetryCallback?("🤖 Connecting to \(UserDefaults.standard.textSearchProvider.description) …")
        switch UserDefaults.standard.aiTextProvider {
        case let .aiModel(model):
            let providerImpl = try getAIImplementation(for: model, telemetryCallback: telemetryCallback)
            let analysisPrompt = try AIPrompts.getAnalysisPrompt(.query(query), responseSchema: AIAnalysisResult.schemaText)

            if let stats = AIUsageStatistics.getStatistics(model: model, requestType: .text),
               stats.averageSuccessProcessingTime > 0
            {
                let eta = String(format: "%.1f", stats.averageSuccessProcessingTime)
                telemetryCallback?("ETA: \(eta)")
            } else {
                telemetryCallback?("ETA: \(String(format: "%.1f", model.defaultTextETA))")
            }

            telemetryCallback?("MODEL: \(model.description)")

            let startTime = Date()

            do {
                let result = try await providerImpl.analyzeText(
                    prompt: analysisPrompt,
                    telemetryCallback: telemetryCallback
                )

                let processingTime = Date().timeIntervalSince(startTime)
                AIUsageStatistics.recordRequest(
                    model: model,
                    requestType: .text,
                    processingTime: processingTime,
                    success: true,
                    foodItemCount: result.foodItems.count
                )

                return result
            } catch {
                let processingTime = Date().timeIntervalSince(startTime)
                AIUsageStatistics.recordRequest(
                    model: model,
                    requestType: .text,
                    processingTime: processingTime,
                    success: false
                )
                throw error
            }
        }
    }

    func analyzeBarcode(
        _ barcode: String,
        telemetryCallback: (@Sendable(String) -> Void)?
    ) async throws -> FoodItemGroup {
        telemetryCallback?("🤖 Connecting to \(UserDefaults.standard.barcodeSearchProvider.description) …")
        switch UserDefaults.standard.barcodeSearchProvider {
        case .openFoodFacts:
            return try await OpenFoodFactsService.shared.analyzeBarcode(
                barcode: barcode,
                telemetryCallback: telemetryCallback
            )
        }
    }

    private func getApiKey(for model: AIModel, telemetryCallback _: ((String) -> Void)?) throws -> String {
        let key: String
        switch model {
        case .gemini:
            key = UserDefaults.standard.googleGeminiAPIKey
            guard !key.isEmpty else {
                print("No API key configured for Google Gemini")
                throw AIFoodAnalysisError.noApiKey
            }
        case .openAI:
            key = UserDefaults.standard.openAIAPIKey
            guard !key.isEmpty else {
                print("No API key configured for OpenAI")
                throw AIFoodAnalysisError.noApiKey
            }
        case .claude:
            key = UserDefaults.standard.claudeAPIKey
            guard !key.isEmpty else {
                print("No API key configured for Claude")
                throw AIFoodAnalysisError.noApiKey
            }
        }
        return key
    }

    private func getAIImplementation(
        for model: AIModel,
        telemetryCallback: ((String) -> Void)?
    ) throws -> AIAnalysisService {
        let apiKey = try getApiKey(for: model, telemetryCallback: telemetryCallback)
        return AIAnalysisService.create(for: model, apiKey: apiKey)
    }
}
