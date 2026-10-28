import Foundation

/// HDBSCAN clustering over a precomputed distance matrix, the algorithm Safari
/// uses for its tab clusters (`WBSHdbscanCluster`). Points that don't belong to
/// any dense group come back as noise (-1) instead of being forced into one.
/// For a browser's tab count (tens), the O(n²) steps are instant.
nonisolated enum HDBSCAN {
    /// - Parameters:
    ///   - distances: symmetric n×n matrix.
    ///   - minimumClusterSize: smallest group worth reporting.
    ///   - neighbors: the k-th nearest point (counting itself) sets each point's core distance.
    /// - Returns: a cluster label per point, or -1 for noise. Labels are 0, 1, 2…
    static func labels(distances: [[Double]], minimumClusterSize: Int, neighbors: Int,
                       allowSingleCluster: Bool = false) -> [Int] {
        let n = distances.count
        guard n >= minimumClusterSize, minimumClusterSize >= 2 else { return Array(repeating: -1, count: n) }

        // Core distance: how far a point must reach to have `neighbors` points around it.
        let core = (0..<n).map { i -> Double in
            let sorted = distances[i].sorted()
            return sorted[min(max(neighbors, 1), n) - 1]
        }
        func reach(_ i: Int, _ j: Int) -> Double { max(core[i], core[j], distances[i][j]) }

        // Minimum spanning tree of the mutual-reachability graph (Prim).
        var inTree = [Bool](repeating: false, count: n)
        var best = [Double](repeating: .infinity, count: n)
        var from = [Int](repeating: -1, count: n)
        var edges: [(a: Int, b: Int, weight: Double)] = []
        best[0] = 0
        for _ in 0..<n {
            var next = -1
            for i in 0..<n where !inTree[i] && (next == -1 || best[i] < best[next]) { next = i }
            inTree[next] = true
            if from[next] >= 0 { edges.append((from[next], next, best[next])) }
            for j in 0..<n where !inTree[j] && reach(next, j) < best[j] {
                best[j] = reach(next, j)
                from[j] = next
            }
        }
        edges.sort { $0.weight < $1.weight }

        // Single-linkage dendrogram: leaves 0..<n, merges n..<2n-1.
        var union = Array(0..<(2 * n))
        func root(_ x: Int) -> Int {
            var x = x
            while union[x] != x { union[x] = union[union[x]]; x = union[x] }
            return x
        }
        var parent = Array(0..<(2 * n))
        var children: [[Int]] = Array(repeating: [], count: 2 * n)
        var size = [Int](repeating: 1, count: 2 * n)
        var height = [Double](repeating: 0, count: 2 * n)
        var nextNode = n
        for edge in edges {
            let (ra, rb) = (root(edge.a), root(edge.b))
            guard ra != rb else { continue }
            let node = nextNode
            nextNode += 1
            union[ra] = node
            union[rb] = node
            parent[ra] = node
            parent[rb] = node
            children[node] = [ra, rb]
            size[node] = size[ra] + size[rb]
            height[node] = edge.weight
        }
        let top = nextNode - 1
        func lambda(_ distance: Double) -> Double { 1 / max(distance, 1e-9) }
        func leaves(_ node: Int) -> [Int] { node < n ? [node] : children[node].flatMap(leaves) }

        // Condensed tree: follow each cluster down, dropping branches smaller than the minimum.
        struct Cluster {
            var birth: Double
            var parent: Int?
            var children: [Int] = []
            var exits: [(point: Int, lambda: Double)] = []
        }
        var clusters: [Cluster] = [Cluster(birth: 0, parent: nil)]
        func condense(_ node: Int, into cluster: Int) {
            guard node >= n else {
                clusters[cluster].exits.append((node, lambda(height[parent[node]])))
                return
            }
            let level = lambda(height[node])
            let (left, right) = (children[node][0], children[node][1])
            let bigLeft = size[left] >= minimumClusterSize, bigRight = size[right] >= minimumClusterSize
            if bigLeft && bigRight {
                for child in [left, right] {
                    clusters.append(Cluster(birth: level, parent: cluster))
                    let id = clusters.count - 1
                    clusters[cluster].children.append(id)
                    condense(child, into: id)
                }
            } else {
                for child in [left, right] {
                    if size[child] >= minimumClusterSize {
                        condense(child, into: cluster)
                    } else {
                        for point in leaves(child) { clusters[cluster].exits.append((point, level)) }
                    }
                }
            }
        }
        condense(top, into: 0)

        // Stability, then excess-of-mass selection from the leaves up (never the root).
        func members(_ c: Int) -> [Int] { clusters[c].exits.map(\.point) + clusters[c].children.flatMap(members) }
        var stability = [Double](repeating: 0, count: clusters.count)
        for c in clusters.indices {
            let birth = clusters[c].birth
            stability[c] = clusters[c].exits.reduce(0) { $0 + ($1.lambda - birth) }
                + clusters[c].children.reduce(0) { $0 + Double(members($1).count) * (clusters[$1].birth - birth) }
        }
        var selected = Set<Int>()
        var score = stability
        for c in clusters.indices.reversed() where c != 0 || (allowSingleCluster && clusters.count == 1) {
            let childScore = clusters[c].children.reduce(0) { $0 + score[$1] }
            if clusters[c].children.isEmpty || stability[c] >= childScore {
                selected.insert(c)
                var stack = clusters[c].children
                while let d = stack.popLast() { selected.remove(d); stack += clusters[d].children }
            } else {
                score[c] = childScore
            }
        }

        var labels = [Int](repeating: -1, count: n)
        for (label, c) in selected.sorted().enumerated() {
            for point in members(c) { labels[point] = label }
        }
        return labels
    }
}
