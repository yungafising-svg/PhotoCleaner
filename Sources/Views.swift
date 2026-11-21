import SwiftUI
import Photos
import UIKit

// MARK: - Главный экран

struct ContentView: View {
    @EnvironmentObject var scanner: Scanner
    @AppStorage(Keys.scope) private var scope = 1000
    @State private var showSettings = false
    @State private var showTrash = false

    var body: some View {
        NavigationStack {
            Group {
                switch scanner.auth {
                case .authorized, .limited:
                    main
                case .notDetermined:
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60))
                        Text("Нужен доступ к фото, чтобы найти дубликаты и неудачные кадры. Всё считается на телефоне, интернет не используется.")
                            .multilineTextAlignment(.center)
                        Button("Разрешить доступ") { Task { await scanner.requestAccess() } }
                            .buttonStyle(.borderedProminent)
                    }.padding()
                default:
                    ContentUnavailableView("Нет доступа к фото",
                                           systemImage: "lock",
                                           description: Text("Настройки → Чистка фото → Фото → Полный доступ"))
                }
            }
            .navigationTitle("Чистка фото")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $showTrash) { TrashView() }
        }
    }

    private var main: some View {
        List {
            Section {
                if scanner.phase == .scanning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scanner.stage).font(.headline)
                        ProgressView(value: scanner.progress)
                        Text("\(scanner.processed) из \(scanner.total)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Остановить", role: .destructive) { scanner.cancel() }
                } else if scanner.phase == .done {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Можно освободить").font(.subheadline).foregroundStyle(.secondary)
                        Text(formatBytes(scanner.reclaimableTotal)).font(.system(size: 40, weight: .bold))
                        Text("на дублях и похожих, лучшие кадры останутся").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Button {
                        scanner.smartCleanup()
                        showTrash = true
                    } label: {
                        Label("Умная очистка", systemImage: "wand.and.stars").bold()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanner.groups.isEmpty)
                    .listRowSeparator(.hidden)
                }
                Picker("Какие фото", selection: $scope) {
                    Text("Последние 500").tag(500)
                    Text("Последние 1000").tag(1000)
                    Text("Последние 5000").tag(5000)
                    Text("Все").tag(0)
                }
                if scanner.phase != .scanning {
                    Button(scanner.phase == .done ? "Сканировать заново" : "Начать сканирование") {
                        scanner.start(limit: scope == 0 ? nil : scope)
                    }
                    .bold()
                }
            } footer: {
                if scanner.phase == .done {
                    Text("Неудачные, но единственные кадры не трогаем — это память. Скриншоты с паролями, документами, деньгами, билетами, адресами, контактами и QR защищены. Избранное, фото из альбомов и отредактированные — тоже. Повторный скан проверяет только новые фото.")
                }
            }

            if scanner.phase == .done {
                Section("Проверить") {
                    if !scanner.liveFixes.isEmpty {
                        NavigationLink { LiveFixView() } label: {
                            row("Живые фото: есть кадр лучше", "livephoto", scanner.liveFixes.count)
                        }
                    }
                    NavigationLink { GroupsView() } label: {
                        row("Похожие и дубликаты", "square.on.square", scanner.groups.count)
                    }
                    NavigationLink { ScreenshotsView() } label: {
                        row("Скриншоты на проверку", "iphone", scanner.screenshotsCheck.count)
                    }
                    NavigationLink { FlaggedGridView(title: "Случайные кадры", list: \.accidental) } label: {
                        row("Случайные кадры", "camera.metering.unknown", scanner.visible(scanner.accidental).count)
                    }
                }
                if scanner.skipped > 0 {
                    Text("Пропущено \(scanner.skipped) фото — они лежат только в iCloud.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Вручную") {
                NavigationLink { MonthsView() } label: {
                    Label("Свайп по месяцам", systemImage: "hand.draw")
                }
            }

            Section {
                NavigationLink { TrashView() } label: {
                    HStack {
                        Label("Корзина", systemImage: "trash")
                        Spacer()
                        Text(scanner.decisions.trash.isEmpty ? "пусто" : "\(scanner.decisions.trash.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if scanner.decisions.freedBytes > 0 {
                    Text("Всего освобождено: \(formatBytes(scanner.decisions.freedBytes))")
                }
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Группы похожих

struct CompareTarget: Identifiable {
    let id = UUID()
    let ids: [String]
    let start: String
    let isGroup: Bool
}

struct GroupsView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var compare: CompareTarget?

    var body: some View {
        List {
            if scanner.groups.isEmpty {
                ContentUnavailableView("Дубликатов нет", systemImage: "checkmark.seal")
            }
            ForEach(scanner.groups, id: \.self) { group in
                GroupRow(group: group, compare: $compare)
            }
        }
        .navigationTitle("Похожие")
        .toolbar {
            Button("Отметить лишние") { scanner.smartCleanup() }
        }
        .safeAreaInset(edge: .bottom) { TrashBar() }
        .fullScreenCover(item: $compare) { CompareView(target: $0) }
    }
}

struct GroupRow: View {
    @EnvironmentObject var scanner: Scanner
    let group: [String]
    @Binding var compare: CompareTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.count) похожих · \(formatBytes(scanner.reclaimable(group)))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Отметить лишние") {
                        scanner.addToTrash(Array(group.dropFirst()))
                    }
                    Button("Это не дубли", systemImage: "xmark.circle") {
                        scanner.markNotDuplicates(group)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            Text("Лучшее: \(scanner.reason(for: group))")
                .font(.caption).foregroundStyle(.green)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group, id: \.self) { id in
                        if let p = scanner.photos[id] {
                            SelectableThumb(asset: p.asset,
                                            selected: scanner.inTrash(id),
                                            badge: id == group.first ? "лучшее" : nil,
                                            locked: scanner.isProtected(id),
                                            onExpand: { compare = CompareTarget(ids: group, start: id, isGroup: true) })
                                .frame(width: 110)
                                .onTapGesture { scanner.toggleTrash(id) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Сетка помеченных фото

struct FlaggedGridView: View {
    @EnvironmentObject var scanner: Scanner
    let title: String
    let list: KeyPath<Scanner, [String]>
    @State private var compare: CompareTarget?
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        let ids = scanner.visible(scanner[keyPath: list])
        let allIn = !ids.isEmpty && ids.allSatisfy { scanner.inTrash($0) }
        ScrollView {
            if ids.isEmpty {
                ContentUnavailableView("Ничего не найдено", systemImage: "checkmark.seal")
                    .padding(.top, 80)
            } else {
                Text("Тап — в корзину, ⤢ — крупно")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    if let p = scanner.photos[id] {
                        SelectableThumb(asset: p.asset,
                                        selected: scanner.inTrash(id),
                                        onExpand: { compare = CompareTarget(ids: ids, start: id, isGroup: false) })
                            .onTapGesture { scanner.toggleTrash(id) }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle(title)
        .toolbar {
            if !ids.isEmpty {
                Button(allIn ? "Снять все" : "Выбрать все") {
                    if allIn { scanner.removeFromTrash(ids) } else { scanner.addToTrash(ids) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { TrashBar() }
        .fullScreenCover(item: $compare) { CompareView(target: $0) }
    }
}

// MARK: - Скриншоты

struct ScreenshotsView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var tab = 0
    @State private var compare: CompareTarget?
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        let ids = tab == 0 ? scanner.visible(scanner.screenshotsCheck) : scanner.screenshotsImportant
        let allIn = !ids.isEmpty && ids.allSatisfy { scanner.inTrash($0) }
        ScrollView {
            Picker("", selection: $tab) {
                Text("На проверку · \(scanner.visible(scanner.screenshotsCheck).count)").tag(0)
                Text("Важные · \(scanner.screenshotsImportant.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text(tab == 0
                 ? "Паролей, документов, денег, билетов, адресов, контактов и QR здесь не нашёл. Сначала — без текста, потом самые старые. Тап — в корзину, ⤢ — крупно с распознанным текстом."
                 : "Здесь нашлось важное. Приложение не предложит их удалить. ⤢ — посмотреть, что именно найдено.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            if ids.isEmpty {
                ContentUnavailableView("Пусто", systemImage: "checkmark.seal").padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    if let p = scanner.photos[id] {
                        SelectableThumb(asset: p.asset,
                                        selected: scanner.inTrash(id),
                                        locked: tab == 1,
                                        onExpand: { compare = CompareTarget(ids: ids, start: id, isGroup: false) })
                            .overlay(alignment: .topLeading) {
                                if !p.tags.isEmpty {
                                    Text(p.tags.map(\.emoji).joined())
                                        .font(.caption)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(4)
                                }
                            }
                            .onTapGesture {
                                if tab == 0 {
                                    scanner.toggleTrash(id)
                                } else {
                                    compare = CompareTarget(ids: ids, start: id, isGroup: false)
                                }
                            }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle("Скриншоты")
        .toolbar {
            if tab == 0 && !ids.isEmpty {
                NavigationLink {
                    SwipeView(title: "Скриншоты", assets: ids.compactMap { scanner.photos[$0]?.asset })
                } label: {
                    Image(systemName: "hand.draw")
                }
                Button(allIn ? "Снять все" : "Выбрать все") {
                    if allIn { scanner.removeFromTrash(ids) } else { scanner.addToTrash(ids) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { TrashBar() }
        .fullScreenCover(item: $compare) { CompareView(target: $0) }
    }
}

// MARK: - Крупный просмотр и сравнение

struct CompareView: View {
    @EnvironmentObject var scanner: Scanner
    @Environment(\.dismiss) private var dismiss
    let target: CompareTarget
    @State private var current = ""

    var body: some View {
        let index = target.ids.firstIndex(of: current) ?? 0
        VStack(spacing: 0) {
            HStack {
                Button("Готово") { dismiss() }.bold()
                Spacer()
                Text("\(index + 1) из \(target.ids.count)")
            }
            .padding()
            .foregroundStyle(.white)

            TabView(selection: $current) {
                ForEach(target.ids, id: \.self) { id in
                    Group {
                        if let a = scanner.asset(id) {
                            ZoomableAsset(asset: a)
                        } else {
                            Color.black
                        }
                    }
                    .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if !current.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        if target.isGroup && scanner.groups.first(where: { $0.contains(current) })?.first == current {
                            Label("лучшее", systemImage: "star.fill").foregroundStyle(.green)
                        }
                        if scanner.isProtected(current) {
                            Label("защищено", systemImage: "lock.fill").foregroundStyle(.yellow)
                        }
                        if let p = scanner.photos[current] {
                            Text("резкость \(Int(p.m.sharpness))")
                            if let fq = p.m.faceQuality { Text("лица \(Int(fq * 100))%") }
                            Text(formatBytes(p.bytes))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))

                    if let p = scanner.photos[current], p.isScreenshot {
                        VStack(alignment: .leading, spacing: 4) {
                            if p.tags.isEmpty {
                                Text("Важного не нашёл — проверь сам").font(.caption.bold()).foregroundStyle(.orange)
                            } else {
                                Text("Важное: " + p.tags.map { $0.emoji + " " + $0.label }.joined(separator: ", "))
                                    .font(.caption.bold()).foregroundStyle(.yellow)
                            }
                            ScrollView {
                                Text((p.text ?? "").isEmpty ? "текста нет" : (p.text ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 110)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 10) {
                        if target.isGroup {
                            Button { scanner.setBest(current) } label: {
                                Label("Лучший", systemImage: "star")
                            }
                        }
                        Button {
                            scanner.toggleTrash(current, force: true)
                        } label: {
                            Label(scanner.inTrash(current) ? "Вернуть" : "В корзину",
                                  systemImage: scanner.inTrash(current) ? "arrow.uturn.backward" : "trash")
                        }
                        .tint(.red)
                        Button { scanner.toggleProtected(current) } label: {
                            Label(scanner.decisions.protected.contains(current) ? "Снять защиту" : "Не трогать",
                                  systemImage: "lock")
                        }
                        .tint(.yellow)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { current = target.start }
    }
}

/// Фото из библиотеки с зумом
struct ZoomableAsset: View {
    let asset: PHAsset
    var body: some View {
        let a = asset
        ZoomableImage(key: a.localIdentifier) { await ImageLoader.image(for: a, side: 2400, network: true) }
    }
}

/// Картинка с зумом щипком и двойным тапом
struct ZoomableImage: UIViewRepresentable {
    let key: String
    let load: () async -> UIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.delegate = context.coordinator
        sv.backgroundColor = .black

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            iv.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = iv

        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)

        let loader = load
        Task { @MainActor in
            iv.image = await loader()
        }
        return sv
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            sv.setZoomScale(sv.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

// MARK: - Свайп по месяцам

struct MonthBucket: Identifiable, @unchecked Sendable {
    let id: String          // "2026-11"
    let title: String
    let assets: [PHAsset]
}

struct MonthsView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var months: [MonthBucket] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(months) { m in
                let done = m.assets.filter { scanner.decisions.swipeReviewed.contains($0.localIdentifier) }.count
                NavigationLink { SwipeView(title: m.title, assets: m.assets) } label: {
                    HStack {
                        Text(m.title)
                        Spacer()
                        if done == m.assets.count {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("\(done)/\(m.assets.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Свайп по месяцам")
        .task {
            guard months.isEmpty else { return }
            months = await Task.detached(priority: .userInitiated) { Self.loadMonths() }.value
            loading = false
        }
    }

    nonisolated static func loadMonths() -> [MonthBucket] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM"
        let titleFmt = DateFormatter()
        titleFmt.locale = Locale(identifier: "ru_RU")
        titleFmt.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var byKey: [String: [PHAsset]] = [:]
        var titles: [String: String] = [:]
        fetch.enumerateObjects { a, _, _ in
            let d = a.creationDate ?? .distantPast
            let k = keyFmt.string(from: d)
            if byKey[k] == nil {
                order.append(k)
                titles[k] = titleFmt.string(from: d).capitalized
            }
            byKey[k, default: []].append(a)
        }
        return order.map { MonthBucket(id: $0, title: titles[$0] ?? $0, assets: byKey[$0] ?? []) }
    }
}

struct SwipeView: View {
    @EnvironmentObject var scanner: Scanner
    let title: String
    let assets: [PHAsset]
    @State private var index = 0
    @State private var history: [(id: String, keep: Bool)] = []
    @State private var drag: CGSize = .zero
    @State private var started = false
    @State private var compare: CompareTarget?

    var body: some View {
        VStack(spacing: 16) {
            if index < assets.count {
                Text("\(index + 1) из \(assets.count) · тап — крупно").font(.caption).foregroundStyle(.secondary)
                ZStack {
                    SwipeCard(asset: assets[index])
                        .id(assets[index].localIdentifier)
                        .onTapGesture {
                            let id = assets[index].localIdentifier
                            compare = CompareTarget(ids: [id], start: id, isGroup: false)
                        }
                        .offset(drag)
                        .rotationEffect(.degrees(Double(drag.width / 20)))
                        .overlay(alignment: .top) {
                            if drag.width < -40 {
                                badge("УДАЛИТЬ", .red)
                            } else if drag.width > 40 {
                                badge("ОСТАВИТЬ", .green)
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { drag = $0.translation }
                                .onEnded { v in
                                    if v.translation.width < -120 { decide(keep: false) }
                                    else if v.translation.width > 120 { decide(keep: true) }
                                    else { withAnimation(.spring()) { drag = .zero } }
                                }
                        )
                }
                .padding(.horizontal)
            } else {
                ContentUnavailableView("Месяц разобран", systemImage: "checkmark.circle",
                                       description: Text("Отмеченные фото лежат в корзине — удалишь их одним нажатием."))
            }

            HStack(spacing: 28) {
                circleButton("xmark", .red) { decide(keep: false) }
                    .disabled(index >= assets.count)
                circleButton("arrow.uturn.backward", .gray) { undo() }
                    .disabled(history.isEmpty)
                circleButton("heart.fill", .green) { decide(keep: true) }
                    .disabled(index >= assets.count)
            }
            .padding(.bottom, 8)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { TrashBar() }
        .fullScreenCover(item: $compare) { CompareView(target: $0) }
        .onAppear {
            guard !started else { return }
            started = true
            index = assets.firstIndex { !scanner.decisions.swipeReviewed.contains($0.localIdentifier) } ?? assets.count
        }
    }

    private func decide(keep: Bool) {
        guard index < assets.count else { return }
        let id = assets[index].localIdentifier
        if !keep { scanner.addToTrash([id], force: true) }
        scanner.markSwipeReviewed(id, true)
        history.append((id, keep))
        drag = .zero
        index += 1
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        if !last.keep { scanner.removeFromTrash([last.id]) }
        scanner.markSwipeReviewed(last.id, false)
        index = max(0, index - 1)
        drag = .zero
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.title2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(color, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 24)
    }

    private func circleButton(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.bold())
                .frame(width: 64, height: 64)
                .background(color.opacity(0.15), in: Circle())
                .foregroundStyle(color)
        }
    }
}

struct SwipeCard: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView()
            }
        }
        .frame(maxHeight: 520)
        .task { image = await ImageLoader.image(for: asset, side: 1400, network: true) }
    }
}

// MARK: - Корзина

struct TrashView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var assets: [PHAsset] = []
    @State private var bytes: Int64 = 0
    @State private var busy = false
    @State private var compare: CompareTarget?
    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 4)]

    var body: some View {
        ScrollView {
            if assets.isEmpty {
                ContentUnavailableView("Корзина пуста", systemImage: "trash",
                                       description: Text("Отмечай фото в разделах или в свайп-режиме — они соберутся здесь для финальной проверки."))
                    .padding(.top, 80)
            } else {
                Text("\(assets.count) фото · \(formatBytes(bytes)). Тап — вернуть, ⤢ — крупно.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(assets, id: \.localIdentifier) { a in
                        SelectableThumb(asset: a, selected: true, onExpand: {
                            compare = CompareTarget(ids: assets.map(\.localIdentifier), start: a.localIdentifier, isGroup: false)
                        })
                        .onTapGesture { scanner.removeFromTrash([a.localIdentifier]) }
                    }
                }
                .padding(4)
            }
        }
        .navigationTitle("Корзина")
        .toolbar {
            if !assets.isEmpty {
                Button("Очистить") { scanner.removeFromTrash(assets.map(\.localIdentifier)) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !assets.isEmpty {
                VStack(spacing: 4) {
                    Button {
                        Task {
                            busy = true
                            _ = await scanner.emptyTrash()
                            busy = false
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text("Удалить \(assets.count) фото · \(formatBytes(bytes))").bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(busy)
                    Text("Фото 30 дней можно восстановить в «Недавно удалённых».")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .fullScreenCover(item: $compare) { CompareView(target: $0) }
        .task(id: scanner.decisions.trash) { reload() }
    }

    private func reload() {
        let ids = Array(scanner.decisions.trash)
        var list: [PHAsset] = []
        if !ids.isEmpty {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: opts).enumerateObjects { a, _, _ in list.append(a) }
        }
        assets = list
        bytes = list.reduce(0) { $0 + (scanner.photos[$1.localIdentifier]?.bytes ?? Analyzer.fileSize($1)) }
    }
}

/// Плашка внизу экранов: сколько в корзине и переход к проверке
struct TrashBar: View {
    @EnvironmentObject var scanner: Scanner

    var body: some View {
        if !scanner.decisions.trash.isEmpty {
            NavigationLink { TrashView() } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("В корзине: \(scanner.decisions.trash.count)")
                    Spacer()
                    Text("Проверить и удалить")
                    Image(systemName: "chevron.right")
                }
                .bold()
                .padding()
                .foregroundStyle(.white)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Живые фото: замена титульного кадра

struct LiveCompareTarget: Identifiable {
    let id: String
}

struct LiveFixView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var busy: Set<String> = []
    @State private var compare: LiveCompareTarget?

    var body: some View {
        let ids = scanner.liveFixes.keys.sorted {
            (scanner.photos[$0]?.date ?? .distantPast) > (scanner.photos[$1]?.date ?? .distantPast)
        }
        List {
            Section {
                ForEach(ids, id: \.self) { id in
                    if let fix = scanner.liveFixes[id], let p = scanner.photos[id] {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                VStack(spacing: 4) {
                                    Thumb(asset: p.asset).frame(width: 130)
                                    Text("сейчас").font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                VStack(spacing: 4) {
                                    Color.gray.opacity(0.15)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay { Image(uiImage: fix.preview).resizable().scaledToFill() }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .frame(width: 130)
                                    Text("предлагаю").font(.caption).foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { compare = LiveCompareTarget(id: id) }
                            HStack {
                                Button {
                                    Task {
                                        busy.insert(id)
                                        await scanner.applyFixes([id])
                                        busy.remove(id)
                                    }
                                } label: {
                                    if busy.contains(id) {
                                        ProgressView()
                                    } else {
                                        Label("Сделать титульным", systemImage: "checkmark")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                                Button("Сравнить") { compare = LiveCompareTarget(id: id) }
                                    .buttonStyle(.bordered)
                                Button("Оставить как есть") { scanner.skipLiveFix(id) }
                                    .buttonStyle(.bordered)
                                    .tint(.gray)
                            }
                            .disabled(!busy.isEmpty)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("Тап по паре — сравнить крупно. Фото остаётся живым, меняется только титульный кадр. Вернуть как было: Фото → Изменить → Вернуть.")
            }
        }
        .navigationTitle("Живые фото")
        .fullScreenCover(item: $compare) { LiveCompareView(id: $0.id) }
        .alert("Не получилось",
               isPresented: Binding(get: { scanner.lastError != nil },
                                    set: { if !$0 { scanner.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanner.lastError ?? "")
        }
    }
}

/// Крупное сравнение: текущий титульный кадр и предлагаемый
struct LiveCompareView: View {
    @EnvironmentObject var scanner: Scanner
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var showNew = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Готово") { dismiss() }.bold()
                Spacer()
            }
            .padding()
            .foregroundStyle(.white)

            Picker("", selection: $showNew) {
                Text("Сейчас").tag(false)
                Text("Предлагаю").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if let p = scanner.photos[id], let fix = scanner.liveFixes[id] {
                let asset = p.asset
                let time = fix.time
                Group {
                    if showNew {
                        ZoomableImage(key: id + "-new") { await LiveFrames.frameImage(asset, time: time) }
                            .id("new")
                    } else {
                        ZoomableAsset(asset: asset)
                            .id("old")
                    }
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    Button {
                        Task {
                            await scanner.applyFixes([id])
                            dismiss()
                        }
                    } label: { Label("Сделать титульным", systemImage: "checkmark") }
                    .tint(.green)
                    Button {
                        scanner.skipLiveFix(id)
                        dismiss()
                    } label: { Label("Оставить как есть", systemImage: "xmark") }
                    .tint(.gray)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            } else {
                Spacer()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @EnvironmentObject var scanner: Scanner
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.similar) private var similar = Thresholds.defaults.similar
    @AppStorage(Keys.blur) private var blur = Thresholds.defaults.blur
    @AppStorage(Keys.protectAlbums) private var protectAlbums = true
    @AppStorage(Keys.protectEdited) private var protectEdited = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Не трогать фото из моих альбомов", isOn: $protectAlbums)
                    Toggle("Не трогать отредактированные", isOn: $protectEdited)
                    HStack {
                        Text("Отмечено «не трогать»")
                        Spacer()
                        Text("\(scanner.decisions.protected.count)").foregroundStyle(.secondary)
                    }
                    if !scanner.decisions.protected.isEmpty {
                        Button("Сбросить список «не трогать»", role: .destructive) { scanner.resetProtected() }
                    }
                } header: { Text("Защита") } footer: {
                    Text("Избранное защищено всегда.")
                }
                Section {
                    Slider(value: $similar, in: 0.1...0.8)
                    Text(String(format: "%.2f", similar)).foregroundStyle(.secondary)
                } header: { Text("Похожесть") } footer: {
                    Text("Больше — в группы попадает больше фото. Меньше — только почти одинаковые.")
                }
                Section {
                    Slider(value: $blur, in: 20...800)
                    Text("\(Int(blur))").foregroundStyle(.secondary)
                } header: { Text("Смаз в живых фото") } footer: {
                    Text("Ниже этого порога приложение поищет в живом фото более резкий кадр. Оценивается объект, а не фон.")
                }
                Section {
                    Button("Пороги по умолчанию") {
                        let d = Thresholds.defaults
                        similar = d.similar; blur = d.blur
                    }
                    Button("Проанализировать всё заново", role: .destructive) { scanner.resetCache() }
                } footer: {
                    Text("Новые пороги применяются сразу, пересканировать не нужно.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        Task { await scanner.reclassify() }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Компоненты

struct Thumb: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: asset.localIdentifier) {
                image = await ImageLoader.image(for: asset, side: 300, network: true)
            }
    }
}

struct SelectableThumb: View {
    let asset: PHAsset
    let selected: Bool
    var badge: String? = nil
    var locked: Bool = false
    var onExpand: (() -> Void)? = nil

    var body: some View {
        Thumb(asset: asset)
            .opacity(selected ? 0.6 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.red : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: locked ? "lock.fill" : (selected ? "trash.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(locked ? Color.yellow : (selected ? Color.red : Color.white))
                    .shadow(radius: 2)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Крупный просмотр по долгому нажатию
struct BigPreview: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        let ratio = asset.pixelWidth > 0 ? CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth) : 1
        let width: CGFloat = 340
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: min(width * ratio, 600))
        .task { image = await ImageLoader.image(for: asset, side: 1200, network: true) }
    }
}
