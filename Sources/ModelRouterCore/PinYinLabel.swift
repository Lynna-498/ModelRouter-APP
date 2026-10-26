import Foundation

// MARK: - 通用路由的供应商标签（模型 ID 前缀）
// 纯英文名照抄；含中文等非 ASCII 名称转无声调全拼并大写、滤掉非字母数字（智谱 → ZHIPU）。
public enum PinYinLabel {
    public static func label(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed.allSatisfy({ $0.isASCII && !$0.isWhitespace }) { return trimmed }
        let s = NSMutableString(string: trimmed)
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        let filtered = (s as String).uppercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? trimmed : filtered
    }

    /// 宽松匹配：先精确相等，再比较转换后的标签（大小写不敏感）
    public static func matches(vendorName: String, label: String) -> Bool {
        if vendorName == label { return true }
        return PinYinLabel.label(for: vendorName).uppercased() == label.uppercased()
    }
}
