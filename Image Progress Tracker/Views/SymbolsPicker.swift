import SwiftUI

struct SymbolsPicker: View {
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    @Binding var icon: String

    var body: some View {
        LazyVGrid(columns: columns) {
            ForEach(Symbols.all, id: \.self) { shownIcon in
                Image(systemName: shownIcon)
                    .font(.largeTitle)
                    .foregroundStyle(icon == shownIcon ? Color.blue : Color.primary)
                    .padding(.top)
                    .onTapGesture {
                        withAnimation {
                            icon = shownIcon
                        }
                    }
            }
        }
    }
}

#Preview {
    SymbolsPicker(icon: .constant(Symbols.defaultSymbol))
}
