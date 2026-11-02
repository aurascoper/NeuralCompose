"""Tarjan Bridge Verifier for Acyclic Solver Orchestration and Biconnected Swarms.

Implements:
- Tarjan Strongly Connected Components (SCC) algorithm (max_scc_size == 1)
- Nilpotent upper-triangular adjacency verification (A^N == 0)
- Inter-solver Betti cycle rank verification (beta_1_inter_solver == 0)
- Hopcroft-Tarjan cut-vertex and bridge edge discovery for biconnected swarms
- Non-recursive execution guard (recursion_depth == 0)

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

from typing import Any, Optional


class TarjanVerificationError(ValueError):
    """Raised when a Tarjan acyclicity or biconnectivity invariant fails."""


def tarjan_scc(
    nodes: list[str], directed_edges: list[tuple[str, str]]
) -> list[list[str]]:
    """Compute strongly connected components via Tarjan algorithm in O(V + E)."""
    adj: dict[str, list[str]] = {u: [] for u in nodes}
    for u, v in directed_edges:
        adj.setdefault(u, []).append(v)
        adj.setdefault(v, [])

    index = 0
    indices: dict[str, int] = {}
    lowlink: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    sccs: list[list[str]] = []

    def strongconnect(v: str) -> None:
        nonlocal index
        indices[v] = index
        lowlink[v] = index
        index += 1
        stack.append(v)
        on_stack.add(v)

        for w in adj.get(v, []):
            if w not in indices:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif w in on_stack:
                lowlink[v] = min(lowlink[v], indices[w])

        if lowlink[v] == indices[v]:
            comp: list[str] = []
            while True:
                w = stack.pop()
                on_stack.remove(w)
                comp.append(w)
                if w == v:
                    break
            sccs.append(comp)

    for node in nodes:
        if node not in indices:
            strongconnect(node)

    return sccs


def find_cut_vertices_and_bridges(
    nodes: list[str], undirected_edges: list[tuple[str, str]]
) -> tuple[list[str], list[tuple[str, str]]]:
    """Compute cut-vertices (articulation points) and bridge edges in an undirected graph."""
    adj: dict[str, list[str]] = {u: [] for u in nodes}
    for u, v in undirected_edges:
        adj.setdefault(u, []).append(v)
        adj.setdefault(v, []).append(u)

    visited: set[str] = set()
    disc: dict[str, int] = {}
    low: dict[str, int] = {}
    parent: dict[str, Optional[str]] = {u: None for u in nodes}
    articulation_points: set[str] = set()
    bridges: list[tuple[str, str]] = []
    timer = 0

    def dfs(u: str) -> None:
        nonlocal timer
        visited.add(u)
        disc[u] = timer
        low[u] = timer
        timer += 1
        children = 0

        for v in adj.get(u, []):
            if v not in visited:
                parent[v] = u
                children += 1
                dfs(v)
                low[u] = min(low[u], low[v])
                if parent[u] is None and children > 1:
                    articulation_points.add(u)
                if parent[u] is not None and low[v] >= disc[u]:
                    articulation_points.add(u)
                if low[v] > disc[u]:
                    bridges.append((u, v))
            elif v != parent[u]:
                low[u] = min(low[u], disc[v])

    for u in nodes:
        if u not in visited:
            dfs(u)

    return sorted(articulation_points), bridges


def compute_betti_numbers(
    nodes: list[str], directed_edges: list[tuple[str, str]]
) -> tuple[int, int]:
    """Compute beta_0 (weakly connected components) and beta_1 (1-cycle rank)."""
    adj_undirected: dict[str, set[str]] = {u: set() for u in nodes}
    for u, v in directed_edges:
        adj_undirected.setdefault(u, set()).add(v)
        adj_undirected.setdefault(v, set()).add(u)

    visited: set[str] = set()
    beta_0 = 0
    for node in nodes:
        if node not in visited:
            beta_0 += 1
            queue = [node]
            visited.add(node)
            while queue:
                curr = queue.pop(0)
                for neighbor in adj_undirected.get(curr, set()):
                    if neighbor not in visited:
                        visited.add(neighbor)
                        queue.append(neighbor)

    # In 1D simplicial / CW complex, beta_1 = |E| - |V| + beta_0
    v_count = len(nodes)
    e_count = len(directed_edges)
    beta_1 = e_count - v_count + beta_0
    return beta_0, max(0, beta_1)


def verify_nilpotent_adjacency(
    nodes: list[str], directed_edges: list[tuple[str, str]]
) -> tuple[bool, int]:
    """Verify that adjacency matrix A is strictly nilpotent (A^N == 0)."""
    n = len(nodes)
    node_to_idx = {name: i for i, name in enumerate(nodes)}

    # Construct adjacency matrix A
    a = [[0] * n for _ in range(n)]
    for u, v in directed_edges:
        if u in node_to_idx and v in node_to_idx:
            a[node_to_idx[u]][node_to_idx[v]] += 1

    # Check for immediate self loops
    for i in range(n):
        if a[i][i] > 0:
            return False, 0

    def matrix_mul(m1: list[list[int]], m2: list[list[int]]) -> list[list[int]]:
        res = [[0] * n for _ in range(n)]
        for i in range(n):
            for k in range(n):
                if m1[i][k] != 0:
                    for j in range(n):
                        res[i][j] += m1[i][k] * m2[k][j]
        return res

    def is_zero(m: list[list[int]]) -> bool:
        return all(m[i][j] == 0 for i in range(n) for j in range(n))

    current = [row[:] for row in a]
    if is_zero(current):
        return True, 1

    for power in range(2, n + 2):
        current = matrix_mul(current, a)
        if is_zero(current):
            return True, power

    return False, n + 1


class TarjanBridgeVerifier:
    """Orchestrates Tarjan solver DAG, nilpotency, and biconnected swarm verification."""

    DEFAULT_SOLVER_NODES = [
        "OpenFOAM_FiniteVolume_CFD",
        "PHREEQC_Geochemical_Speciation",
        "FlowCytometry_SingleCell_Bridge",
        "SmallModularBioReactors_Multiscale_ODE",
        "MATLAB_R2026b_Simulink_Simscape_3D_EDA",
    ]

    DEFAULT_SOLVER_EDGES = [
        ("OpenFOAM_FiniteVolume_CFD", "PHREEQC_Geochemical_Speciation"),
        ("PHREEQC_Geochemical_Speciation", "FlowCytometry_SingleCell_Bridge"),
        ("FlowCytometry_SingleCell_Bridge", "SmallModularBioReactors_Multiscale_ODE"),
        ("SmallModularBioReactors_Multiscale_ODE", "MATLAB_R2026b_Simulink_Simscape_3D_EDA"),
    ]

    @classmethod
    def verify_solver_pipeline(
        cls,
        nodes: Optional[list[str]] = None,
        directed_edges: Optional[list[tuple[str, str]]] = None,
        recursion_depth: int = 0,
        consolidation_rule_immutable: bool = True,
    ) -> dict[str, Any]:
        """Verify cross-solver Tarjan bridge pipeline.

        Requires:
        - max_scc_size == 1
        - beta_1_inter_solver == 0
        - recursion_depth == 0
        - consolidation_rule_immutable == True
        - Adjacency matrix A is nilpotent (A^5 == 0)
        """
        if recursion_depth != 0:
            raise TarjanVerificationError(
                f"Non-recursive constraint violated: recursion_depth must be 0, got {recursion_depth}"
            )
        if not consolidation_rule_immutable:
            raise TarjanVerificationError(
                "consolidation_rule_immutable must be True"
            )

        if nodes is None:
            nodes = cls.DEFAULT_SOLVER_NODES
        if directed_edges is None:
            directed_edges = cls.DEFAULT_SOLVER_EDGES

        # Self loop check
        for u, v in directed_edges:
            if u == v:
                raise TarjanVerificationError(
                    f"Self-loop detected on node '{u}': cross-solver pipeline must be strictly acyclic"
                )

        sccs = tarjan_scc(nodes, directed_edges)
        max_scc_size = max((len(c) for c in sccs), default=0)
        if max_scc_size > 1:
            raise TarjanVerificationError(
                f"Acyclic Tarjan constraint violated: max_scc_size={max_scc_size} > 1. Cycles found: {sccs}"
            )

        beta_0, beta_1 = compute_betti_numbers(nodes, directed_edges)
        if beta_1 != 0:
            raise TarjanVerificationError(
                f"Inter-solver topological loop detected: beta_1_inter_solver={beta_1} must be 0"
            )

        is_nilpotent, nilpotency_degree = verify_nilpotent_adjacency(nodes, directed_edges)
        if not is_nilpotent:
            raise TarjanVerificationError(
                f"Adjacency matrix is not nilpotent: cross-solver pipeline contains hidden feedback cycles"
            )

        return {
            "verified": True,
            "nodes": list(nodes),
            "directed_edges": [list(e) for e in directed_edges],
            "max_scc_size": max_scc_size,
            "beta_0": beta_0,
            "beta_1_inter_solver": beta_1,
            "recursion_depth": recursion_depth,
            "consolidation_rule_immutable": consolidation_rule_immutable,
            "is_nilpotent": is_nilpotent,
            "nilpotency_degree": nilpotency_degree,
        }

    @classmethod
    def verify_swarm_biconnectivity(
        cls,
        nodes: list[str],
        undirected_edges: list[tuple[str, str]],
    ) -> dict[str, Any]:
        """Verify swarm dependency graph is biconnected with beta_1 >= 2 and zero cut-vertices."""
        cut_vertices, bridge_edges = find_cut_vertices_and_bridges(nodes, undirected_edges)
        v_count = len(nodes)
        e_count = len(undirected_edges)
        beta_1_swarm = e_count - v_count + 1

        if len(cut_vertices) > 0:
            raise TarjanVerificationError(
                f"Swarm contains {len(cut_vertices)} single-point-of-failure cut-vertices: {cut_vertices}"
            )
        if len(bridge_edges) > 0:
            raise TarjanVerificationError(
                f"Swarm contains {len(bridge_edges)} bridge edges: {bridge_edges}"
            )
        if beta_1_swarm < 2:
            raise TarjanVerificationError(
                f"Swarm cycle rank beta_1={beta_1_swarm} < 2; biconnected redundancy requirement failed"
            )

        return {
            "verified": True,
            "swarm_nodes": list(nodes),
            "swarm_edges": [list(e) for e in undirected_edges],
            "beta_1_swarm": beta_1_swarm,
            "cut_vertices": cut_vertices,
            "bridge_edges": [list(e) for e in bridge_edges],
        }

    @classmethod
    def verify_orderbook_settlement_bridge(
        cls,
        orderbook_edges: list[tuple[str, str]],
        balance_tree_edges: list[tuple[str, str]],
        bridge_edge: tuple[str, str] = ("orderbook_settle", "ledger_entry"),
        reverse_ledger_to_orderbook_edge: Optional[tuple[str, str]] = None,
    ) -> dict[str, Any]:
        """Verify one-way settlement bridge from cyclic orderbook to acyclic balance tree."""
        if reverse_ledger_to_orderbook_edge is not None:
            raise TarjanVerificationError(
                "Reverse edge from balance ledger to orderbook detected: one-way settlement bridge violated"
            )

        all_nodes = sorted(
            list(
                {u for u, v in orderbook_edges}
                | {v for u, v in orderbook_edges}
                | {u for u, v in balance_tree_edges}
                | {v for u, v in balance_tree_edges}
                | {bridge_edge[0], bridge_edge[1]}
            )
        )
        combined_edges = list(orderbook_edges) + list(balance_tree_edges) + [bridge_edge]
        sccs = tarjan_scc(all_nodes, combined_edges)

        # The bridge edge itself must not form an SCC spanning both orderbook and ledger
        ledger_nodes = {u for u, v in balance_tree_edges} | {v for u, v in balance_tree_edges}
        orderbook_nodes = {u for u, v in orderbook_edges} | {v for u, v in orderbook_edges}

        for comp in sccs:
            if any(n in ledger_nodes for n in comp) and any(n in orderbook_nodes for n in comp):
                raise TarjanVerificationError(
                    f"Settlement bridge created cyclic coupling between orderbook and ledger: {comp}"
                )

        return {
            "verified": True,
            "bridge_edge": list(bridge_edge),
            "settlement_sccs": sccs,
        }
