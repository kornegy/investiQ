import SwiftUI
import InvestiQPresentation

/// Main window: sidebar with the ten sections (docs/UI_UX.md §2).
struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let selection = Binding<AppSection?>(
            get: { app.selectedSection },
            set: { if let section = $0 { app.selectedSection = section } })
        NavigationSplitView {
            List(AppSection.allCases, selection: selection) { section in
                Label {
                    Text(LocalizedStringKey(section.titleKey))
                } icon: {
                    SidebarIcon(systemName: section.systemImage)
                }
                .tag(section)
                .accessibilityIdentifier("sidebar.\(section.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Button { Task { await app.lock(reason: .manual) } } label: {
                    Label {
                        Text(LocalizedStringKey(app.isDemo ? "demo.exit" : "menu.lock"))
                    } icon: {
                        SidebarIcon(systemName: app.isDemo ? "xmark.circle" : "lock")
                    }
                }
                .buttonStyle(.borderless)
                .padding(Spacing.m)
            }
        } detail: {
            VStack(spacing: 0) {
                if app.isDemo { DemoBanner() }
                if app.educationalMode { EducationalModeBanner() }
                SectionContainer(section: app.selectedSection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SectionContainer: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .settings:
            SettingsView()
        case .market:
            MarketView()
        case .overview:
            OverviewView()
        case .portfolio:
            PortfolioView()
        case .risk:
            RiskView()
        case .planner:
            PlannerView()
        case .simulator:
            SimulatorView()
        case .learn:
            LearnView()
        case .news:
            NewsView()
        case .brokers:
            BrokersView()
        }
    }
}

struct EducationalModeBanner: View {
    var body: some View {
        Label("educationalMode.banner", systemImage: "graduationcap")
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(Spacing.s)
            .background(Color.blue.opacity(0.12))
    }
}

/// SF Symbols have different natural proportions (`graduationcap` is wide, `list.bullet.clipboard` is
/// tall). A fixed box keeps every sidebar row the same height and every title at the same x.
struct SidebarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .imageScale(.medium)
            .frame(width: IconSize.sidebar, height: IconSize.sidebar)
    }
}

extension AppSection {
    /// Outline symbols only, so no icon looks heavier than its neighbours.
    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .market: return "chart.line.uptrend.xyaxis"
        case .portfolio: return "briefcase"
        case .news: return "newspaper"
        case .risk: return "exclamationmark.shield"
        case .planner: return "list.bullet.clipboard"
        case .simulator: return "play.rectangle"
        case .brokers: return "building.columns"
        case .learn: return "graduationcap"
        case .settings: return "gearshape"
        }
    }
}
