import SwiftUI
import Photos

// MARK: - Главный экран

struct ContentView: View {
    @EnvironmentObject var scanner: Scanner
    @AppStorage(Keys.scope) private var scope = 1000
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch scanner.auth {
                case .authorized, .limited:
                    main
                case .notDetermined:
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60))
                        Text("Нужен доступ к фото, чтобы найти дубликаты и неудачные кадры. Всё считается на телефоне.")
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
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var main: some View {
        List {
            Section("Сканирование") {
                Picker("Какие фото", selection: $scope) {
                    Text("Последние 500").tag(500)
                    Text("Последние 1000").tag(1000)
                    Text("Последние 5000").tag(5000)
                    Text("Все").tag(0)
                }
                if scanner.phase == .scanning {
                    ProgressView(value: scanner.progress) {
                        Text("Проверено \(scanner.processed) из \(scanner.total)")
                    }
                    Button("Остановить", role: .destructive) { scanner.cancel() }
                } else {
                    Button(scanner.phase == .done ? "Сканировать заново" : "Начать сканирование") {
                        scanner.start(limit: scope == 0 ? nil : scope)
                    }
                    .bold()
                }
            }

            if scanner.phase == .done {
                Section("Результаты") {
                    NavigationLink { GroupsView() } label: {
                        row("Похожие и дубликаты", "square.on.square", scanner.extraInGroups)
                    }
                    NavigationLink { FlaggedGridView(title: "Размытые", list: \.blurry) } label: {
                        row("Размытые", "camera.metering.unknown", scanner.blurry.count)
                    }
                    NavigationLink { FlaggedGridView(title: "Тёмные / пересвет", list: \.badExposure) } label: {
                        row("Тёмные и пересвеченные", "sun.max", scanner.badExposure.count)
                    }
                    NavigationLink { FlaggedGridView(title: "Неудачные лица", list: \.badFaces) } label: {
                        row("Закрытые глаза / смаз лица", "face.dashed", scanner.badFaces.count)
                    }
                    NavigationLink { FlaggedGridView(title: "Скриншоты", list: \.screenshots) } label: {
                        row("Скриншоты", "iphone", scanner.screenshots.count)
                    }
                }
                if scanner.skipped > 0 {
                    Text("Пропущено \(scanner.skipped) фото — они лежат только в iCloud.")
                        .font(.footnote).foregroundStyle(.secondary)
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

struct GroupsView: View {
    @EnvironmentObject var scanner: Scanner
    @State private var selected: Set<String> = []
    @State private var didInit = false

    var body: some View {
        List {
            if scanner.groups.isEmpty {
                ContentUnavailableView("Дубликатов нет", systemImage: "checkmark.seal")
            }
            ForEach(scanner.groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(group.count) похожих").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(group, id: \.self) { id in
                                if let p = scanner.photos[id] {
                                    SelectableThumb(asset: p.asset,
                                                    selected: selected.contains(id),
                                                    badge: id == group.first ? "лучшее" : nil)
                                        .frame(width: 110)
                                        .onTapGesture { toggle(id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Похожие")
        .toolbar {
            Button(selected.isEmpty ? "Выбрать лишние" : "Снять все") {
                selected = selected.isEmpty ? Set(scanner.groups.flatMap { $0.dropFirst() }) : []
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                DeleteBar(count: selected.count) {
                    if await scanner.delete(Array(selected)) { selected.removeAll() }
                }
            }
        }
        .onAppear {
            guard !didInit else { return }
            selected = Set(scanner.groups.flatMap { $0.dropFirst() })   // всё, кроме лучшего
            didInit = true
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

// MARK: - Сетка помеченных фото

struct FlaggedGridView: View {
    @EnvironmentObject var scanner: Scanner
    let title: String
    let list: KeyPath<Scanner, [String]>
    @State private var selected: Set<String> = []
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        let ids = scanner[keyPath: list]
        ScrollView {
            if ids.isEmpty {
                ContentUnavailableView("Ничего не найдено", systemImage: "checkmark.seal")
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    if let p = scanner.photos[id] {
                        SelectableThumb(asset: p.asset, selected: selected.contains(id))
                            .onTapGesture { toggle(id) }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle(title)
        .toolbar {
            if !ids.isEmpty {
                Button(selected.count == ids.count ? "Снять все" : "Выбрать все") {
                    selected = selected.count == ids.count ? [] : Set(ids)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                DeleteBar(count: selected.count) {
                    if await scanner.delete(Array(selected)) { selected.removeAll() }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

// MARK: - Настройки порогов

struct SettingsView: View {
    @EnvironmentObject var scanner: Scanner
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.similar) private var similar = Thresholds.defaults.similar
    @AppStorage(Keys.blur) private var blur = Thresholds.defaults.blur
    @AppStorage(Keys.dark) private var dark = Thresholds.defaults.dark
    @AppStorage(Keys.bright) private var bright = Thresholds.defaults.bright
    @AppStorage(Keys.face) private var face = Thresholds.defaults.face

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Slider(value: $similar, in: 0.1...0.8)
                    Text(String(format: "%.2f", similar)).foregroundStyle(.secondary)
                } header: { Text("Похожесть") } footer: {
                    Text("Больше — в группы попадает больше фото. Меньше — только почти одинаковые.")
                }
                Section {
                    Slider(value: $blur, in: 20...500)
                    Text("\(Int(blur))").foregroundStyle(.secondary)
                } header: { Text("Размытость") } footer: {
                    Text("Больше — строже, больше фото считаются размытыми.")
                }
                Section("Экспозиция") {
                    Stepper("Темнее чем: \(Int(dark))", value: $dark, in: 5...100, step: 5)
                    Stepper("Светлее чем: \(Int(bright))", value: $bright, in: 150...250, step: 5)
                }
                Section {
                    Slider(value: $face, in: 0.05...0.6)
                    Text(String(format: "%.2f", face)).foregroundStyle(.secondary)
                } header: { Text("Качество лица") } footer: {
                    Text("Больше — строже к закрытым глазам и смазанным лицам.")
                }
                Section {
                    Button("Сбросить по умолчанию") {
                        let d = Thresholds.defaults
                        similar = d.similar; blur = d.blur; dark = d.dark; bright = d.bright; face = d.face
                    }
                } footer: { Text("Пересканировать не нужно — новые пороги применяются сразу.") }
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

    var body: some View {
        Thumb(asset: asset)
            .opacity(selected ? 0.7 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.red : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.red : Color.white)
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
            .contentShape(Rectangle())
            .contextMenu {
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
            } preview: {
                BigPreview(asset: asset)
            }
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

struct DeleteBar: View {
    let count: Int
    let action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            Task { busy = true; await action(); busy = false }
        } label: {
            HStack {
                if busy { ProgressView().tint(.white) }
                Text("Удалить выбранные (\(count))").bold()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(busy)
        .padding()
        .background(.ultraThinMaterial)
    }
}
