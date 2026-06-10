import SwiftUI

// MARK: - Search state

extension MediaTab {
    struct ResolvedSearchHit: Identifiable {
        let hit: SearchHit
        let asset: MediaAsset
        var id: String { hit.id }
    }

    var semanticSearchKey: String {
        "\(trimmedSearchQuery)#\(editor.mediaIndexer.revision)"
    }

    func resolvedHits(_ hits: [SearchHit]) -> [ResolvedSearchHit] {
        hits.compactMap { hit in
            editor.mediaAssets.first(where: { $0.id == hit.assetId })
                .map { ResolvedSearchHit(hit: hit, asset: $0) }
        }
    }

    @ViewBuilder
    var visualSearchControl: some View {
        switch EmbeddingService.shared.visualState {
        case .unknown, .notInstalled:
            Button { EmbeddingService.shared.downloadVisualModels() } label: {
                Text("Enable visual search")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .buttonStyle(.plain)
            .focusable(false)
        case .downloading(let progress):
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView(value: progress).controlSize(.small)
                    .frame(width: AppTheme.Moments.thumbWidth)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
            }
        case .preparing:
            Text("Preparing\u{2026}")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        case .ready:
            EmptyView()
        case .failed:
            Button { EmbeddingService.shared.downloadVisualModels() } label: {
                Text("Visual search failed — retry")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }
}

// MARK: - Unified scroll (search active)

extension MediaTab {
    var unifiedMediaScrollArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    unifiedScrollContent(width: geo.size.width)
                }
                .coordinateSpace(name: "mediaGrid")
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    assetFrames = frames
                    let cols = gridDimensions(width: geo.size.width).cols
                    if editor.mediaPanelColumnCount != cols { editor.mediaPanelColumnCount = cols }
                }
                .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    editor.mediaPanelScrollTarget = nil
                }
                .onTapGesture { clearSelections() }
                .overlay { marqueeOverlay }
                .gesture(marqueeGesture)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func unifiedScrollContent(width: CGFloat) -> some View {
        let dims = gridDimensions(width: width)
        let visualHits = resolvedHits(semanticResults.visual)
        let spokenHits = resolvedHits(semanticResults.spoken)
        let libraryOrderedIds = unifiedLibraryOrderedIds

        VStack(alignment: .leading, spacing: 0) {
            searchStatusContent

            searchSection(
                title: "Library",
                count: libraryOrderedIds.count,
                icon: "folder",
                collapsed: $librarySectionCollapsed
            ) {
                if libraryOrderedIds.isEmpty {
                    searchItemCountLabel(libraryOrderedIds.count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    embeddedLibraryContent(width: width, dims: dims)
                }
            }

            if !visualHits.isEmpty {
                searchSection(title: "Visual", count: visualHits.count, icon: "eye", collapsed: $visualSectionCollapsed) {
                    segmentGridContent(hits: visualHits, dims: dims)
                }
                .padding(.top, AppTheme.Spacing.sm)
            }

            if !spokenHits.isEmpty {
                searchSection(title: "Spoken", count: spokenHits.count, icon: "waveform", collapsed: $spokenSectionCollapsed) {
                    spokenListContent(hits: spokenHits, query: trimmedSearchQuery)
                }
                .padding(.top, AppTheme.Spacing.sm)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { publishOrderedIds(libraryOrderedIds) }
        .onChange(of: libraryOrderedIds) { _, ids in publishOrderedIds(ids) }
    }

    private var unifiedLibraryOrderedIds: [String] {
        switch viewMode {
        case .folder:
            return computeLayout(width: mediaPanelWidth).orderedIds
        case .flat:
            return sortAndFilter(editor.mediaAssets).map(\.id)
        case .grouped:
            let bucketed = editor.mediaAssets.reduce(into: [String?: [MediaAsset]]()) { dict, asset in
                dict[asset.folderId, default: []].append(asset)
            }
            let rootAssets = sortAndFilter(bucketed[nil] ?? [])
            var orderedIds = collapsedGroupedKeys.contains("") ? [] : rootAssets.map(\.id)
            let allFolders = editor.folders
                .map { ($0, editor.folderPath(for: $0.id).map(\.name).joined(separator: " / ")) }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            for (folder, _) in allFolders where !collapsedGroupedKeys.contains(folder.id) {
                orderedIds.append(contentsOf: sortAndFilter(bucketed[folder.id] ?? []).map(\.id))
            }
            return orderedIds
        }
    }

    @ViewBuilder
    private func embeddedLibraryContent(width: CGFloat, dims: GridDimensions) -> some View {
        switch viewMode {
        case .folder:
            embeddedFolderGrid(width: width, dims: dims)
        case .flat:
            embeddedFlatGrid(dims: dims)
        case .grouped:
            embeddedGroupedGrid(dims: dims)
        }
    }

    @ViewBuilder
    var searchStatusContent: some View {
        let showVisualControl: Bool = {
            switch EmbeddingService.shared.visualState {
            case .ready: false
            default: true
            }
        }()
        if editor.mediaIndexer.indexingActive || showVisualControl {
            HStack(spacing: AppTheme.Spacing.sm) {
                if editor.mediaIndexer.indexingActive {
                    let indexer = editor.mediaIndexer
                    ProgressView(value: indexer.indexingProgress)
                        .controlSize(.small)
                        .frame(width: AppTheme.Moments.indexingBarWidth)
                    Text("Indexing \(indexer.batchCompleted + 1)/\(indexer.batchTotal) · \(Int(indexer.indexingProgress * 100))%")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                visualSearchControl
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    func searchItemCountLabel(_ count: Int) -> some View {
        Text(count == 1 ? "1 item" : "\(count) items")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .monospacedDigit()
    }

    @ViewBuilder
    func searchSection<Content: View>(
        title: String,
        count: Int,
        icon: String,
        collapsed: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SearchCollapsibleSection(title: title, count: count, icon: icon, collapsed: collapsed, content: content)
    }

    @ViewBuilder
    func segmentGridContent(
        hits: [ResolvedSearchHit],
        dims: GridDimensions
    ) -> some View {
        let columns = Array(repeating: GridItem(.fixed(dims.tileWidth), spacing: dims.spacing), count: max(dims.cols, 1))
        LazyVGrid(columns: columns, alignment: .leading, spacing: dims.spacing) {
            ForEach(hits) { item in
                segmentCard(item, tileWidth: dims.tileWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func spokenListContent(hits: [ResolvedSearchHit], query: String) -> some View {
        let metrics = spokenRowMetrics
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, item in
                spokenListRow(item, query: query, metrics: metrics)
                if index < hits.count - 1 {
                    Divider()
                        .padding(.leading, metrics.thumbWidth + AppTheme.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct SpokenRowMetrics {
        let thumbWidth: CGFloat
        let thumbHeight: CGFloat
        let nameFontSize: CGFloat
        let metaFontSize: CGFloat
        let snippetFontSize: CGFloat
        let snippetLineLimit: Int
        let rowPadding: CGFloat
    }

    var spokenRowMetrics: SpokenRowMetrics {
        let thumbWidth = CGFloat(thumbnailSize)
        let thumbHeight = thumbWidth * 9 / 16
        switch thumbnailSize {
        case ...90:
            return SpokenRowMetrics(
                thumbWidth: thumbWidth, thumbHeight: thumbHeight,
                nameFontSize: AppTheme.FontSize.xs, metaFontSize: AppTheme.FontSize.xxs,
                snippetFontSize: AppTheme.FontSize.xxs, snippetLineLimit: 2,
                rowPadding: AppTheme.Spacing.xs
            )
        case ...130:
            return SpokenRowMetrics(
                thumbWidth: thumbWidth, thumbHeight: thumbHeight,
                nameFontSize: AppTheme.FontSize.sm, metaFontSize: AppTheme.FontSize.xxs,
                snippetFontSize: AppTheme.FontSize.xs, snippetLineLimit: 3,
                rowPadding: AppTheme.Spacing.sm
            )
        case ...175:
            return SpokenRowMetrics(
                thumbWidth: thumbWidth, thumbHeight: thumbHeight,
                nameFontSize: AppTheme.FontSize.smMd, metaFontSize: AppTheme.FontSize.xs,
                snippetFontSize: AppTheme.FontSize.xs, snippetLineLimit: 3,
                rowPadding: AppTheme.Spacing.sm
            )
        default:
            return SpokenRowMetrics(
                thumbWidth: thumbWidth, thumbHeight: thumbHeight,
                nameFontSize: AppTheme.FontSize.md, metaFontSize: AppTheme.FontSize.xs,
                snippetFontSize: AppTheme.FontSize.sm, snippetLineLimit: 4,
                rowPadding: AppTheme.Spacing.smMd
            )
        }
    }

    // MARK: - Segment cards

    private func segmentCard(_ item: ResolvedSearchHit, tileWidth: CGFloat) -> some View {
        let hit = item.hit
        let asset = item.asset
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                segmentThumbnail(hit: hit, asset: asset)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                Text(segmentTimeLabel(hit: hit, asset: asset))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(AppTheme.Spacing.xs)
            }
            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .frame(width: tileWidth)
        .contentShape(Rectangle())
        .onTapGesture { openSearchHit(hit, asset: asset) }
        .draggable(MediaTab.assetDragString(forAssetId: hit.assetId, segmentStart: hit.start, segmentEnd: hit.end)) {
            segmentDragPreview(hit: hit, asset: asset)
        }
    }

    private func spokenListRow(_ item: ResolvedSearchHit, query: String, metrics: SpokenRowMetrics) -> some View {
        let hit = item.hit
        let asset = item.asset
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            segmentThumbnail(hit: hit, asset: asset)
                .frame(width: metrics.thumbWidth, height: metrics.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                    Text(asset.name)
                        .font(.system(size: metrics.nameFontSize, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(segmentTimeLabel(hit: hit, asset: asset))
                        .font(.system(size: metrics.metaFontSize, weight: .medium))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                }
                if let snippet = hit.snippet {
                    highlightedSnippet(snippet, query: query)
                        .font(.system(size: metrics.snippetFontSize))
                        .lineLimit(metrics.snippetLineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.vertical, metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { openSearchHit(hit, asset: asset) }
        .draggable(MediaTab.assetDragString(forAssetId: hit.assetId, segmentStart: hit.start, segmentEnd: hit.end)) {
            segmentDragPreview(hit: hit, asset: asset)
        }
    }

    @ViewBuilder
    private func segmentThumbnail(hit: SearchHit, asset: MediaAsset) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image = segmentThumbImage(hit: hit, asset: asset) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: asset.type.sfSymbolName)
                    .font(.system(size: AppTheme.FontSize.lg))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .clipped()
    }

    private func segmentThumbImage(hit: SearchHit, asset: MediaAsset) -> NSImage? {
        switch asset.type {
        case .video:
            guard let frames = editor.mediaVisualCache.thumbnails(for: asset.id), !frames.isEmpty else {
                return asset.thumbnail
            }
            let target = hit.midpoint
            let best = frames.min { abs($0.time - target) < abs($1.time - target) }!
            return NSImage(cgImage: best.image, size: NSSize(width: best.image.width, height: best.image.height))
        case .image:
            if let cg = editor.mediaVisualCache.imageThumbnail(for: asset.id) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return asset.thumbnail
        default:
            return asset.thumbnail
        }
    }

    private func segmentDragPreview(hit: SearchHit, asset: MediaAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            segmentThumbnail(hit: hit, asset: asset)
                .frame(width: AppTheme.Moments.thumbWidth, height: AppTheme.Moments.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            Text(segmentTimeLabel(hit: hit, asset: asset))
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                .monospacedDigit()
        }
        .padding(AppTheme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.prominentColor))
    }

    func openSearchHit(_ hit: SearchHit, asset: MediaAsset) {
        editor.selectMediaAsset(asset)
        guard asset.type != .image else { return }
        let frame = secondsToFrame(seconds: hit.start, fps: editor.timeline.fps)
        editor.seekSourceToFrame(frame)
    }

    private func segmentTimeLabel(hit: SearchHit, asset: MediaAsset) -> String {
        if asset.duration > 0, hit.start <= 0.5, hit.end >= asset.duration - 0.5 {
            return "Full clip"
        }
        return "\(momentTime(hit.start))–\(momentTime(hit.end))"
    }

    private func momentTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: - Highlight

    func highlightedSnippet(_ text: String, query: String) -> Text {
        let words = SemanticSearchEngine.contentWords(query)
        guard !words.isEmpty else {
            return Text(text).foregroundStyle(AppTheme.Text.secondaryColor)
        }
        let lowered = text.lowercased()
        var ranges: [Range<String.Index>] = []
        for word in words {
            var tokenStart = lowered.startIndex
            while tokenStart < lowered.endIndex {
                while tokenStart < lowered.endIndex, !lowered[tokenStart].isLetter, !lowered[tokenStart].isNumber {
                    tokenStart = lowered.index(after: tokenStart)
                }
                guard tokenStart < lowered.endIndex else { break }
                var tokenEnd = tokenStart
                while tokenEnd < lowered.endIndex, lowered[tokenEnd].isLetter || lowered[tokenEnd].isNumber {
                    tokenEnd = lowered.index(after: tokenEnd)
                }
                let token = String(lowered[tokenStart..<tokenEnd])
                if SemanticSearchEngine.sharesStem(token, word) {
                    ranges.append(tokenStart..<tokenEnd)
                }
                tokenStart = tokenEnd
            }
        }
        guard !ranges.isEmpty else {
            return Text(text).foregroundStyle(AppTheme.Text.secondaryColor)
        }
        let merged = mergeRanges(ranges.sorted { $0.lowerBound < $1.lowerBound })
        var parts: [Text] = []
        var cursor = text.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                parts.append(Text(String(text[cursor..<range.lowerBound])).foregroundStyle(AppTheme.Text.secondaryColor))
            }
            parts.append(Text(String(text[range])).foregroundStyle(AppTheme.Accent.primary).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            parts.append(Text(String(text[cursor...])).foregroundStyle(AppTheme.Text.secondaryColor))
        }
        return parts.dropFirst().reduce(parts[0], +)
    }

    private func mergeRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        guard var current = ranges.first else { return [] }
        var merged: [Range<String.Index>] = []
        for range in ranges.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }
}

// MARK: - Collapsible section chrome

private struct SearchCollapsibleSection<Content: View>: View {
    let title: String
    let count: Int
    let icon: String
    @Binding var collapsed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { collapsed.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: AppTheme.IconSize.xs)
                    Image(systemName: icon)
                        .font(.system(size: AppTheme.FontSize.xxs))
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    Text("\(count)")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.vertical, AppTheme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if !collapsed { content() }
        }
    }
}
