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
                Label(LocalizedStringKey(section.titleKey), systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityIdentifier("sidebar.\(section.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Button { Task { await app.lock(reason: .manual) } } label: {
                    Label(app.isDemo ? "demo.exit" : "menu.lock", systemImage: app.isDemo ? "xmark.circle" : "lock")
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
        default:
            SectionPlaceholderView(section: section)
        }
    }
}

/// Honest placeholder for sections whose implementation lands in a later roadmap phase.
struct SectionPlaceholderView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label(LocalizedStringKey(section.titleKey), systemImage: section.systemImage)
        } description: {
            Text("section.notYetAvailable")
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

extension AppSection {
    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .market: return "chart.line.uptrend.xyaxis"
        case .portfolio: return "briefcase"
        case .news: return "newspaper"
        case .risk: return "shield.lefthalf.filled"
        case .planner: return "list.bullet.clipboard"
        case .simulator: return "testtube.2"
        case .brokers: return "building.columns"
        case .learn: return "graduationcap"
        case .settings: return "gearshape"
        }
    }
}
