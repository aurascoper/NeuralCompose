// memory.test.ts — Milestone 3: semantic-graph memory and emergent synthesis.
// Ported from Swift DialecticalMemoryTests.swift.

import { makeEmbedding } from '../dynamics';
import { DialecticalMemory } from '../memory';
import { SemanticGraph } from '../semanticGraph';
import { DEFAULT_TUNING } from '../profiles';
import type { Embedding } from '../types';

function emb(v: number[]): Embedding {
  return makeEmbedding(v, 't');
}

describe('DialecticalMemory', () => {
  // MARK: - SemanticGraph

  test('graph links similar nodes and ranks by proximity', () => {
    const g = new SemanticGraph(8, 0.9);
    g.insert('sea', emb([1, 0]), 0, 'heard');
    g.insert('ocean', emb([0.98, 0.2]), 1, 'reply');
    g.insert('clock', emb([0, 1]), 2, 'reply');

    expect(g.edges.length).toBe(1);
    const near = g.nearestPriorNodes(emb([1, 0]), 2);
    expect(near[0].text).toBe('sea');
    expect(near.map((n) => n.text)).toEqual(['sea', 'ocean']);
  });

  test('graph evicts oldest beyond capacity', () => {
    const g = new SemanticGraph(2, 0.5);
    g.insert('a', emb([1, 0]), 0, 'heard');
    g.insert('b', emb([0, 1]), 1, 'heard');
    g.insert('c', emb([1, 1]), 2, 'heard');
    expect(g.nodes.map((n) => n.text)).toEqual(['b', 'c']);
    expect(g.edges.some((e) => e.a === 0 || e.b === 0)).toBe(false);
  });

  // MARK: - Derived slow-clock quantities

  test('entropy and drift reflect reply movement', () => {
    let focused = new DialecticalMemory(8);
    focused.recordReply('x', emb([1, 0]), 0);
    focused.recordReply('x2', emb([1, 0.02]), 1);

    let wandering = new DialecticalMemory(8);
    wandering.recordReply('a', emb([1, 0]), 0);
    wandering.recordReply('b', emb([0, 1]), 1);

    expect(focused.entropy).toBeLessThan(wandering.entropy);
    expect(focused.drift).toBeLessThan(wandering.drift);
  });

  // MARK: - Synthesis gate

  test('resurfaced bridging idea becomes synthesis candidate', () => {
    const m = new DialecticalMemory(8, 128, 0.6, 0.35);
    m.recordReply('the tide remembers', emb([1, 1, 0]), 0);
    const synth = m.synthesisCandidate(emb([1, 0, 0]), emb([0, 1, 0]), DEFAULT_TUNING);
    expect(synth?.text).toBe('the tide remembers');
    expect(synth?.roleID).toBe('synthesis');
  });

  test('no bridging idea means no synthesis', () => {
    const m = new DialecticalMemory(8, 128, 0.6, 0.35);
    m.recordReply('only thesis', emb([1, 0, 0]), 0);
    const synth = m.synthesisCandidate(emb([1, 0, 0]), emb([0, 1, 0]), DEFAULT_TUNING);
    expect(synth).toBeNull();
  });

  test('sustained convergence lowers the synthesis bar', () => {
    const bridge = emb([1, 0.15, 0]);
    const thesis = emb([1, 0, 0]);
    const antithesis = emb([0, 1, 0]);

    const opposed = new DialecticalMemory(8, 128, 0.6, 0.35);
    opposed.recordReply('bridge', bridge, 0);
    expect(opposed.synthesisCandidate(thesis, antithesis, DEFAULT_TUNING)).toBeNull();

    const converged = new DialecticalMemory(8, 128, 0.6, 0.35);
    converged.recordReply('bridge', bridge, 0);
    for (let i = 0; i < DEFAULT_TUNING.synthesisSustainK; i++) {
      converged.observe(0.1);
    }
    expect(converged.synthesisCandidate(thesis, antithesis, DEFAULT_TUNING)).not.toBeNull();
  });

  test('recently voiced reply is rejected as synthesis', () => {
    const m = new DialecticalMemory(8, 128, 0.6, 0.35);
    m.recordReply('the bridge idea', emb([1, 1, 0]), 0);
    m.recordVoiced('the bridge idea');
    // Now even if it bridges, it should be rejected
    const synth = m.synthesisCandidate(emb([1, 0, 0]), emb([0, 1, 0]), DEFAULT_TUNING);
    expect(synth).toBeNull();
  });
});