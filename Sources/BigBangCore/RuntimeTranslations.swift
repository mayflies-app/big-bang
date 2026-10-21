import Foundation

/// Text shared by the native note, selection reader, and model transport.
public enum RuntimeTranslations {
    /// Only known app-owned errors follow language changes. Unknown errors and
    /// generated output are never interpreted as UI text.
    public static func message(_ message: String, language: AppLanguage) -> String {
        if let key = keys.first(where: { key in
            AppLanguage.allCases.contains { L10n.string(key, language: $0) == message }
        }) {
            return L10n.string(key, language: language)
        }
        for key in formattedFailures {
            for sourceLanguage in AppLanguage.allCases {
                let source = L10n.string(key, language: sourceLanguage)
                let parts = source.components(separatedBy: "%@")
                guard parts.count == 2, message.hasPrefix(parts[0]), message.hasSuffix(parts[1]),
                      message.count >= parts[0].count + parts[1].count else { continue }
                let argument = String(message.dropFirst(parts[0].count).dropLast(parts[1].count))
                return L10n.string(key, language: language).replacingOccurrences(of: "%@", with: argument)
            }
        }
        return message
    }

    private static let formattedFailures = [
        "响应未正常完成（%@），已保留部分结果。",
        "API 请求失败（HTTP %@），请检查服务状态。"
    ]

    private static let keys = [
        "准备连接…",
        "连接中…",
        "正在生成",
        "已完成",
        "请求失败",
        "已停止",
        "已复制",
        "复制",
        "全选",
        "输出内容",
        "停止",
        "重试",
        "取消置顶",
        "保持在最前",
        "关闭（Esc）",
        "跟随输出",
        "请先在便签正文中选中文字，再按快捷键。",
        "当前便签没有选中的文本。",
        "请先在系统设置 → 隐私与安全性 → 辅助功能中允许大爆炸，然后再次触发快捷键。",
        "请先在其他应用中选中文本，再按快捷键。",
        "密码输入框中的文本不会被读取。",
        "当前应用没有提供可读取的选中文本。可在设置中启用复制回退，或换一个支持辅助功能的应用。",
        "当前没有选中的文本。",
        "选中文本超过 100 KB，请缩小选择范围。",
        "前台应用已改变，请重新选择并触发。",
        "请松开快捷键后重新触发，以便复制选中文本。",
        "复制期间前台应用改变，请重试。",
        "当前没有选中的文本。编辑器复制的整行不会被读取。",
        "编辑器提供的复制元数据无效或矛盾，请重新选择并复制。",
        "选择的内容不是文本，或复制尚未完成。",
        "未能复制选中文本。请确认当前应用支持 ⌘C 且已选中文本。",
        "无法发送复制快捷键。",
        "无法注册 %@（%@），可能被其他应用占用。请修改快捷键。",
        "请先在设置中保存 API Key。",
        "连接中断，未收到完成事件。可保留已有内容并重试。",
        "模型响应失败或达到输出限制，可保留已有内容并重试。",
        "响应未正常完成（%@），已保留部分结果。",
        "API Key 无效，请检查设置。",
        "额度不足或请求过于频繁，请稍后重试。",
        "模型不存在或不可用，请修改模型名称。",
        "API 请求失败，请检查端点、接口类型、模型和 API Key。",
        "API Key 无权访问当前端点或模型。",
        "接口或模型不存在，请检查 API 基础地址、接口类型和模型。",
        "API 请求失败（HTTP %@），请检查服务状态。",
        "无法解析模型响应，请确认端点支持所选接口类型。",
        "请求失败，请检查网络、API 端点与服务状态后重试。",
    ]
}
