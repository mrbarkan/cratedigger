import CrateDiggerCore
import SwiftUI

struct InspectorPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var showingEditor = false
    @State private var showingCleanup = false
    @State private var activeTab: InspectorTab = .info

    private enum InspectorTab: String, CaseIterable {
        case info = "INFO"
        case art = "ART"
        case disc = "DISC"
    }

    /// Width threshold above which the inspector switches from the default
    /// vertical layout (poster on top, metadata below) to a wide horizontal
    /// layout (metadata on the left, square poster on the right). Tuned to
    /// the inspector well width when the browser is collapsed: ~580pt+.
    private static let wideLayoutThreshold: CGFloat = 520

    var body: some View {
        ZStack {
            if model.oledView == .conversion {
                ConvertPatchBay()
                    .transition(.opacity)
            } else {
                inspectorContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: model.oledView)
        .sheet(isPresented: $showingEditor) {
            if let track = model.selectedTrack {
                MetadataEditorView(track: track)
            }
        }
        .sheet(isPresented: $showingCleanup) {
            LibraryCleanupView()
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                KeyButton(
                    style: activeTab == tab ? .selected : .normal,
                    action: { activeTab = tab }
                ) {
                    Text(tab.rawValue)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var inspectorContent: some View {
        VStack(spacing: 0) {
            tabSwitcher
            
            GeometryReader { geo in
                if geo.size.width >= Self.wideLayoutThreshold {
                    wideLayout(width: geo.size.width)
                } else {
                    narrowLayout(height: geo.size.height)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeTab)
        }
    }

    // Default vertical layout: tab contents stacked
    @ViewBuilder
    private func narrowLayout(height: CGFloat) -> some View {
        switch activeTab {
        case .info:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    AlbumPoster(album: model.selectedAlbum)
                        .frame(width: 120, height: 120)
                        .padding(.vertical, 14)
                    captionBlock
                    SpecRows(album: model.selectedAlbum)
                    TagChips(album: model.selectedAlbum)
                    utilitiesBlock
                }
            }
            
        case .art:
            ArtworkInspectorView(album: model.selectedAlbum)
                .frame(height: height)
            
        case .disc:
            VStack {
                Spacer()
                SpinningRecordView(model: model)
                    .padding(20)
                Spacer()
            }
            .frame(height: height)
        }
    }

    // Wide layout: metadata column on the left, square album art on the
    // right. Activated when the browser is collapsed and the inspector
    // takes the freed chassis width — better proportions for the artwork
    // and stops the metadata from being squashed.
    @ViewBuilder
    private func wideLayout(width: CGFloat) -> some View {
        let posterSize = min(max(width * 0.45, 280), 460)
        
        switch activeTab {
        case .info:
            HStack(alignment: .top, spacing: 18) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        captionBlock
                        SpecRows(album: model.selectedAlbum)
                        TagChips(album: model.selectedAlbum)
                        utilitiesBlock
                    }
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 0) {
                    AlbumPoster(album: model.selectedAlbum)
                        .frame(width: 140, height: 140)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            
        case .art:
            ArtworkInspectorView(album: model.selectedAlbum)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
        case .disc:
            HStack {
                Spacer()
                SpinningRecordView(model: model)
                    .frame(width: posterSize, height: posterSize)
                Spacer()
            }
            .padding(14)
        }
    }

    private var utilitiesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library Tools".uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink3)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            HStack(spacing: 8) {
                KeyButton(style: model.selectedTrack != nil ? .normal : .disabled, action: {
                    showingEditor = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                        Text("EDIT TAGS")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
                
                KeyButton(style: .normal, action: {
                    showingCleanup = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("CLEANUP")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
                
                KeyButton(style: .normal, action: {
                    model.automaticallyReorganizeLibrary()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text("ORGANIZE")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .top
        )
    }

    @ViewBuilder
    private var captionBlock: some View {
        let album = model.selectedAlbum
        VStack(alignment: .leading, spacing: 5) {
            Text(album?.title ?? "—")
                .font(CarbonFont.sans(19, weight: .heavy))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Text((album?.artistName ?? "—").uppercased())
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                if let year = album?.year {
                    Text("·")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink4)
                    Text(String(year))
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

}

