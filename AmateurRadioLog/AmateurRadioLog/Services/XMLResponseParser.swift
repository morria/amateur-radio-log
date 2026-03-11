import Foundation

final class XMLResponseParser: NSObject, XMLParserDelegate {
    private var elements: [String: String] = [:]
    private var currentElement = ""
    private var currentValue = ""
    private var targetElements: Set<String>?

    func parse(data: Data, targetElements: Set<String>? = nil) -> [String: String] {
        self.elements = [:]
        self.targetElements = targetElements
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return elements
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let targets = targetElements {
                if targets.contains(elementName) {
                    elements[elementName] = trimmed
                }
            } else {
                elements[elementName] = trimmed
            }
        }
    }
}
