import SwiftUI
import WhooshMeetings

/// An in-window drag keeps the native video mounted. Nothing is put on the
/// system pasteboard, and a cancelled/outside drop leaves the order unchanged.
struct MeetingGalleryView<Tile: View>: View {
    var meeting: MeetingCoordinator
    @ViewBuilder var tile: (MeetingParticipant) -> Tile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: GalleryDrag?
    @Namespace private var coordinateSpace

    private struct GalleryDrag {
        let participantID: String
        let sessionID: UUID
        var location: CGPoint
        var translation: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            let people = meeting.visibleParticipants
            let sessionID = meeting.sessionID
            let spacing: CGFloat = people.count > 25 ? 6 : 10
            let frames = MeetingTileArrangement.frames(aspectRatios: people.map(\.tileAspectRatio),
                                                       size: geometry.size, spacing: spacing)
            let destination = drag.flatMap { validDrag in
                validDrag.sessionID == sessionID ? MeetingGalleryDropTarget.index(at: validDrag.location, frames: frames) : nil
            }
            MeetingTileLayout(aspectRatios: people.map(\.tileAspectRatio), spacing: spacing) {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    let isDragging = drag?.participantID == person.id && drag?.sessionID == sessionID
                    tile(person)
                        .overlay {
                            RoundedRectangle(cornerRadius: frames[index].height < 90 ? 7 : 12)
                                .strokeBorder(.blue.opacity(destination == index && !isDragging ? 0.9 : 0), lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(isDragging ? 0.3 : 0), radius: isDragging ? 12 : 0, y: 4)
                        .offset(isDragging ? drag?.translation ?? .zero : .zero)
                        .zIndex(isDragging ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
                            .updating($drag) { value, state, _ in
                                guard let sessionID, meeting.isConnected else { return }
                                state = GalleryDrag(participantID: person.id, sessionID: state?.sessionID ?? sessionID,
                                                    location: value.location, translation: value.translation)
                            }
                            .onEnded { value in
                                guard let sessionID,
                                      let target = MeetingGalleryDropTarget.index(at: value.location, frames: frames),
                                      people.indices.contains(target) else { return }
                                move(person.id, to: people[target].id, sessionID: sessionID)
                            })
                        .contextMenu {
                            Button("Move earlier", systemImage: "arrow.left") {
                                if index > 0, let sessionID { move(person.id, to: people[index - 1].id, sessionID: sessionID) }
                            }.disabled(index == 0)
                            Button("Move later", systemImage: "arrow.right") {
                                if index + 1 < people.count, let sessionID { move(person.id, to: people[index + 1].id, sessionID: sessionID) }
                            }.disabled(index == people.count - 1)
                            Divider()
                            Button("Focus on \(person.name)", systemImage: "pin") { meeting.setPinnedParticipant(person.id) }
                        }
                        .accessibilityAction(named: "Move earlier") {
                            if index > 0, let sessionID { move(person.id, to: people[index - 1].id, sessionID: sessionID) }
                        }
                        .accessibilityAction(named: "Move later") {
                            if index + 1 < people.count, let sessionID { move(person.id, to: people[index + 1].id, sessionID: sessionID) }
                        }
                        .accessibilityHint("Drag to reorder in gallery")
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .background(WhooshWindowInteractionRegion())
        }
    }

    private func move(_ participant: String, to target: String, sessionID: UUID) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            _ = meeting.moveGalleryParticipant(participant, to: target, sessionID: sessionID)
        }
    }
}

enum MeetingGalleryDropTarget {
    static func index(at location: CGPoint, frames: [CGRect]) -> Int? {
        guard location.x.isFinite, location.y.isFinite else { return nil }
        return frames.firstIndex { $0.width > 0 && $0.height > 0 && $0.contains(location) }
    }
}
