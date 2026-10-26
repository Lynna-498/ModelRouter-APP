// MARK: - 长文本参数独立输入窗（自 CodexMetadataWindow 拆分·T9/I34，纯移动）
import SwiftUI
import AppKit
import ModelRouterCore

struct LongTextInputView: View {
    @EnvironmentObject var state: AppState
    let paramKey: String
    let initialText: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(paramKey).font(mono(12.5))
                    .foregroundStyle(keyAccent)
                Text("\(text.count) 字符").font(f(11)).foregroundStyle(ink3)
                Spacer()
            }
            TextEditor(text: $text)
                .font(mono(11)).scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sep, lineWidth: 1))
                .frame(width: 608, height: 380)   // S7：592→608＝窗 640−内衬 32，右侧死柱消除
            HStack {
                Spacer()
                Button("取消") { onCancel() }.cardBtn()
                Button("确定") { onConfirm(text) }.cardBtn(primary: true)
            }
        }
        .padding(16)
        .frame(width: 640, height: 480, alignment: .topLeading)
        .onAppear { text = initialText }
    }
}

// MARK: - 结构化参数独立输入窗口（model_messages 等复杂结构：逐字段表单填写，不整团塞进一个编辑器）
// 字段＝当前 JSON 对象的顶层键（按首现序）；每行＝字段名＋按值形态的编辑控件＋⊖；
// 可添加字段（文本/数字/布尔/JSON 四类）；确定后序列化为 pretty JSON 回填界面状态。
