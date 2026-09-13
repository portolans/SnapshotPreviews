//
//  TextView.swift
//  DemoApp
//
//  Created by Noah Martin on 9/1/23.
//

#if canImport(UIKit)
import Foundation
import SwiftUI

struct TextView: UIViewRepresentable {
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.text = "Some text"
    return view
  }

  func updateUIView(_ uiView: UITextView, context: Context) { }
}

struct TextView_Previews: PreviewProvider {
  static var previews: some View {
    TextView()
  }
}

/// A SwiftUI text field focused via `@FocusState` on appear.
///
/// Focus set this way survives the render-site `endEditing(true)`, so without a caret
/// suppression this preview's snapshot races iOS's caret blink and flakes.
struct FocusedSwiftUIFieldView: View {
  @FocusState private var isFocused: Bool
  @State private var text = ""

  var body: some View {
    TextField("Placeholder", text: $text)
      .textFieldStyle(.roundedBorder)
      .focused($isFocused)
      .padding()
      .onAppear { isFocused = true }
  }
}

struct FocusedSwiftUIFieldView_Previews: PreviewProvider {
  static var previews: some View {
    FocusedSwiftUIFieldView()
  }
}

/// The UIKit counterpart: a `UITextField` made first responder imperatively.
///
/// Present so the SwiftUI fixture above has a control to compare against — the
/// render-site `endEditing(true)` has always been sufficient for this case.
struct FocusedUIKitFieldView: UIViewRepresentable {
  func makeUIView(context: Context) -> UITextField {
    let view = UITextField()
    view.borderStyle = .roundedRect
    view.placeholder = "Placeholder"
    DispatchQueue.main.async { view.becomeFirstResponder() }
    return view
  }

  func updateUIView(_ uiView: UITextField, context: Context) { }
}

struct FocusedUIKitFieldView_Previews: PreviewProvider {
  static var previews: some View {
    FocusedUIKitFieldView()
  }
}


/// A focused field inside a view tall enough to take the Core Animation capture path.
///
/// `requiresCoreAnimationSnapshot` trips at twice the screen height, and that path renders
/// `layer.presentation()` rather than drawing the hierarchy — so an uncommitted hide would
/// still show a caret here even while the shorter fixtures above came out clean.
struct TallFocusedFieldView: View {
  @FocusState private var isFocused: Bool
  @State private var text = ""

  var body: some View {
    VStack {
      TextField("Placeholder", text: $text)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
      Spacer()
    }
    .padding()
    .frame(height: 2000)
    .onAppear { isFocused = true }
  }
}

struct TallFocusedFieldView_Previews: PreviewProvider {
  static var previews: some View {
    TallFocusedFieldView()
  }
}

#endif
