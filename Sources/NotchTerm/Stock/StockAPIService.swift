import Foundation

final class StockAPIService {
    static let shared = StockAPIService()

    private let snapshotEndpoint = "https://hq.sinajs.cn/list="
    private let suggestEndpointBase = "https://suggest3.sinajs.cn/suggest/"

    private func request(_ url: URL, completion: @escaping (Data?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // 新浪对无浏览器 UA 的客户端偶发 456；冷启动首次搜索尤其容易踩中。
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(nil, error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(nil, StockAPIError.httpStatus(http.statusCode))
                return
            }
            completion(data, nil)
        }.resume()
    }

    private static func decodeSinaText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .gbk) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    func fetchSnapshot(symbols: [String], completion: @escaping (Result<[Ticker], Error>) -> Void) {
        guard !symbols.isEmpty else {
            completion(.failure(StockAPIError.emptyRequest))
            return
        }
        guard let url = URL(string: snapshotEndpoint + symbols.joined(separator: ",")) else {
            completion(.failure(StockAPIError.invalidURL))
            return
        }
        request(url) { data, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data, let text = Self.decodeSinaText(data) else {
                DispatchQueue.main.async { completion(.failure(StockAPIError.emptyResponse)) }
                return
            }
            let tickers = Self.parseSnapshot(text)
            DispatchQueue.main.async { completion(.success(tickers)) }
        }
    }

    private static func parseSnapshot(_ input: String) -> [Ticker] {
        let regex = try! NSRegularExpression(pattern: #"var hq_str_([a-z]{2}\d+)="([^"]*)"#)
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        return matches.compactMap { match -> Ticker? in
            guard let symbolRange = Range(match.range(at: 1), in: input),
                  let dataRange = Range(match.range(at: 2), in: input) else { return nil }
            let symbol = String(input[symbolRange])
            let raw = String(input[dataRange])
            guard !raw.isEmpty else { return nil }
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 32 else { return nil }
            func d(_ i: Int) -> Double { Double(parts[i]) ?? 0 }

            let rawShares = d(8)
            let amount = d(9)
            let avgPrice = rawShares > 0 ? amount / rawShares : 0

            func levels(from start: Int) -> [OrderBookLevel] {
                stride(from: start, to: start + 10, by: 2).map {
                    OrderBookLevel(price: d($0 + 1), volume: d($0) / 100)
                }
            }

            return Ticker(
                symbol: symbol,
                name: parts[0],
                price: d(3),
                previousClose: d(2),
                open: d(1),
                high: d(4),
                low: d(5),
                volume: rawShares / 100,
                amount: amount,
                avgPrice: avgPrice,
                buyLevels: levels(from: 10),
                sellLevels: levels(from: 20)
            )
        }
    }

    func searchSuggest(keyword: String, completion: @escaping (Result<[SuggestItem], Error>) -> Void) {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(StockAPIError.invalidURL))
            return
        }
        let urlString = "\(suggestEndpointBase)type=11,12,13,14,15&key=\(encoded)&name=suggest_data"
        guard let url = URL(string: urlString) else {
            completion(.failure(StockAPIError.invalidURL))
            return
        }
        request(url) { data, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data, let text = Self.decodeSinaText(data) else {
                DispatchQueue.main.async { completion(.failure(StockAPIError.emptyResponse)) }
                return
            }
            DispatchQueue.main.async { completion(.success(Self.parseSuggest(text))) }
        }
    }

    /// 按名称搜时 fields[0] 是中文名；按代码搜时 fields[0] 常是 sh/sz 代码，中文名在 fields[4]。
    private static func parseSuggest(_ input: String) -> [SuggestItem] {
        guard let firstQuote = input.firstIndex(of: "\""),
              let lastQuote = input.lastIndex(of: "\""),
              firstQuote < lastQuote
        else { return [] }
        let inner = input[input.index(after: firstQuote)..<lastQuote]
        return inner.split(separator: ";").compactMap { entry -> SuggestItem? in
            let fields = entry.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            let prefixedCode = fields[3].lowercased()
            guard prefixedCode.hasPrefix("sh") || prefixedCode.hasPrefix("sz") else { return nil }
            let name: String = {
                if fields[0].containsCJK { return fields[0] }
                if fields.count > 4, fields[4].containsCJK { return fields[4] }
                return fields.first(where: \.containsCJK) ?? fields[0]
            }()
            return SuggestItem(code: prefixedCode, name: name)
        }
    }
}
