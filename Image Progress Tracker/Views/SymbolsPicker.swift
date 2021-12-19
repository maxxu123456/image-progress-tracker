
import SwiftUI

struct SymbolsPicker: View {
    var columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),GridItem(.flexible())]
    @Binding var icon: String
    var body: some View {

            LazyVGrid(columns: columns) {
                ForEach(symbols, id: \.self) { shownIcon in
                    Image(systemName: shownIcon)
                        .font(.largeTitle)
                        .foregroundColor(icon == shownIcon ? Color.blue : Color.primary)
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

struct SymbolsPicker_Previews: PreviewProvider {
    static var previews: some View {
        SymbolsPicker(icon: .constant(Constants.defaultSymbol))
    }
}
