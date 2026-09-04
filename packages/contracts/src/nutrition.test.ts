import { describe, expect, it } from 'vitest';
import {
  FoodConfirmationRequest,
  FoodEstimateProposal,
  FoodPhotoImageDescriptor,
  FoodPhotoManifest,
  validateFoodConfirmationAgainstProposal,
  validateFoodEstimateProposalAgainstManifest,
} from './nutrition.js';

const now = new Date().toISOString();
const earlier = new Date(Date.now() - 60_000).toISOString();
const future = new Date(Date.now() + 60_000).toISOString();
const hashA = 'a'.repeat(64);
const hashB = 'b'.repeat(64);

const base64ForBytes = (byteLength: number) => {
  const fullGroups = Math.floor(byteLength / 3);
  const remainder = byteLength % 3;
  return 'A'.repeat(fullGroups * 4) + (remainder === 0 ? '' : remainder === 1 ? 'AA==' : 'AAA=');
};

const image = (imageID: string, byteLength = 1, sha256 = hashA) => ({
  imageID,
  mimeType: 'image/jpeg' as const,
  byteLength,
  width: 3_000,
  height: 2_000,
  sanitized: true as const,
  inlineDataBase64: base64ForBytes(byteLength),
  sha256,
});

const manifest = {
  schemaVersion: 1,
  mealID: 'meal-1',
  requestID: 'food-request-1',
  capturedAt: now,
  clientTimeZone: 'Europe/Berlin',
  inferenceConsent: true,
  images: [image('image-a', 1, hashA), image('image-b', 1, hashB)],
  userContext: {
    plateDiameterMm: 270,
    knownReference: 'standard dinner plate',
    portionWeightGrams: 250,
    packageLabelContext: 'plain Greek yogurt, 2 percent fat',
    note: 'Lunch, photographed from above',
  },
} as const;

const range = (estimate: number, min = estimate, max = estimate) => ({ estimate, min, max });

const proposal = {
  schemaVersion: 1,
  mealID: manifest.mealID,
  proposalID: 'proposal-1',
  requestID: manifest.requestID,
  state: 'needs_confirmation',
  generatedAt: now,
  provenance: {
    provider: 'lifeos-food-gateway',
    modelIdentifier: 'gemini-food',
    modelVersion: '2026-08',
    policyVersion: 'nutrition-v1',
    requestTimestamp: now,
    sanitizedImageHashes: [
      { imageID: 'image-a', sha256: hashA },
      { imageID: 'image-b', sha256: hashB },
    ],
  },
  items: [
    {
      itemID: 'item-yogurt', enteredLabel: 'Greek yogurt', estimatedLabel: 'Greek yogurt', labelSource: 'recognized',
      quantity: 1, unit: 'serving', grams: range(200, 190, 210), calories: range(150, 130, 170),
      protein: range(20, 18, 22), carbs: range(8, 6, 10), fat: range(5, 4, 6), fiber: range(0),
      confidence: 'high', uncertaintyNotes: ['Brand and portion were user-provided.'], alternatives: ['Skyr'], flags: ['needs_confirmation'],
    },
    {
      itemID: 'item-berries', estimatedLabel: 'Mixed berries', labelSource: 'assumed',
      quantity: 1, unit: 'portion', grams: range(50, 40, 60), calories: range(50, 40, 60),
      protein: range(1, 0.5, 1.5), carbs: range(12, 10, 14), fat: range(0, 0, 0.5), fiber: range(3, 2, 4),
      confidence: 'medium', uncertaintyNotes: ['Exact fruit mix and portion are uncertain.'], flags: ['needs_confirmation', 'unknown_portion'],
    },
  ],
  totals: {
    grams: range(250, 230, 270), calories: range(200, 170, 230), protein: range(21, 18.5, 23.5),
    carbs: range(20, 16, 24), fat: range(5, 4, 6.5), fiber: range(3, 2, 4),
  },
  flags: ['needs_confirmation', 'unknown_portion'],
  uncertaintyNotes: ['Hidden oil and exact portion remain unverified.'],
} as const;

const confirmedItem = {
  itemID: 'item-yogurt', label: 'Greek yogurt', quantity: 1, unit: 'serving', grams: 200,
  calories: 150, protein: 20, carbs: 8, fat: 5, fiber: 0,
} as const;

const confirmedMeal = {
  schemaVersion: 1,
  mealID: manifest.mealID,
  requestID: manifest.requestID,
  proposalID: proposal.proposalID,
  action: 'confirm',
  mealName: 'Greek yogurt with berries',
  mealAt: now,
  items: [confirmedItem],
  totals: { grams: 200, calories: 150, protein: 20, carbs: 8, fat: 5, fiber: 0 },
  confirmedAt: now,
} as const;

describe('food photo manifest contract', () => {
  it('accepts bounded sanitized inline images and optional user context', () => {
    expect(FoodPhotoManifest.parse(manifest).images).toHaveLength(2);
    expect(FoodPhotoImageDescriptor.parse(image('one')).sanitized).toBe(true);
  });

  it('enforces 1–3 images, per-image and aggregate 20 MiB limits, safe MIME/dimensions, and unique IDs', () => {
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [manifest.images[0], manifest.images[1], image('image-c'), image('image-d')] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], byteLength: 20 * 1024 * 1024 + 1 }] })).toThrow();
    const tenMiB = 10 * 1024 * 1024;
    const atAggregateLimit = { ...manifest, images: [image('image-a', tenMiB, hashA), image('image-b', tenMiB, hashB)] };
    expect(() => FoodPhotoManifest.parse(atAggregateLimit)).not.toThrow();
    const aggregateOverflow = { ...manifest, images: [image('image-a', tenMiB + 1, hashA), image('image-b', tenMiB, hashB)] };
    expect(() => FoodPhotoManifest.parse(aggregateOverflow)).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], mimeType: 'image/gif' }] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], width: 12_001 }] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], width: 10_000, height: 4_001 }] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], imageID: '../image' }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [manifest.images[0], { ...manifest.images[1], imageID: 'image-a' }] })).toThrow();
  });

  it('requires real canonical inline bytes, a sanitization attestation, and a digest', () => {
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], inlineDataBase64: 'data:image/jpeg;base64,AA==' }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], inlineDataBase64: 'AA==\n' }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], byteLength: 2 }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], sanitized: false }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], sha256: 'not-a-sha256' }, manifest.images[1]] })).toThrow();
  });

  it('strictly rejects filename/path/EXIF/GPS, credentials, unknown fields, bad consent, and future times', () => {
    expect(() => FoodPhotoManifest.parse({ ...manifest, capturedAt: future })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, clientTimeZone: 'Europe/../Berlin' })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], filename: 'meal.jpg' }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], path: '/private/meal.jpg' }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], exif: {} }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, images: [{ ...manifest.images[0], gps: { lat: 1, lon: 2 } }, manifest.images[1]] })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, userContext: { ...manifest.userContext, apiKey: 'must-not-pass' } })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, userContext: { ...manifest.userContext, note: 'Bearer abc123' } })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, inferenceConsent: false })).toThrow();
    expect(() => FoodPhotoManifest.parse({ ...manifest, authorization: 'Bearer secret' })).toThrow();
  });
});

describe('food estimate proposal contract', () => {
  it('accepts a versioned proposal only as an explicit needs-confirmation estimate', () => {
    const parsed = FoodEstimateProposal.parse(proposal);
    expect(parsed.schemaVersion).toBe(1);
    expect(parsed.state).toBe('needs_confirmation');
    expect(parsed.flags).toContain('needs_confirmation');
    expect(validateFoodEstimateProposalAgainstManifest(proposal, manifest).proposalID).toBe(proposal.proposalID);
  });

  it('distinguishes recognized and assumed items without requiring user-entered text', () => {
    const recognizedWithoutEnteredLabel = { ...proposal, items: [{ ...proposal.items[0], enteredLabel: undefined }, proposal.items[1]] };
    expect(FoodEstimateProposal.parse(recognizedWithoutEnteredLabel).items[0].labelSource).toBe('recognized');
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[1], labelSource: 'assumed', enteredLabel: 'User supplied clue' }, proposal.items[0]] })).not.toThrow();
  });

  it('binds request, meal, timestamps, and SHA-256 hashes to exactly the manifest images in order', () => {
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, requestID: 'other-request' }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, mealID: 'other-meal' }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, provenance: { ...proposal.provenance, requestTimestamp: earlier } }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, generatedAt: earlier }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, provenance: { ...proposal.provenance, sanitizedImageHashes: [{ imageID: 'image-b', sha256: hashB }, { imageID: 'image-a', sha256: hashA }] } }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, provenance: { ...proposal.provenance, sanitizedImageHashes: [{ imageID: 'image-a', sha256: hashA }] } }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, provenance: { ...proposal.provenance, sanitizedImageHashes: [...proposal.provenance.sanitizedImageHashes, { imageID: 'unrelated', sha256: hashB }] } }, manifest)).toThrow();
    expect(() => validateFoodEstimateProposalAgainstManifest({ ...proposal, provenance: { ...proposal.provenance, sanitizedImageHashes: [{ imageID: 'image-a', sha256: 'c'.repeat(64) }, { imageID: 'image-b', sha256: hashB }] } }, manifest)).toThrow();
  });

  it('rejects stale/confirmed state, accuracy claims, credentials, medical advice, unknown fields, bad ranges, and duplicate items', () => {
    expect(() => FoodEstimateProposal.parse({ ...proposal, state: 'confirmed' })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, accuracyClaim: 'at least 80%' })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, apiKey: 'secret' })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, allergyAdvice: 'avoid dairy' })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], diagnosis: 'not allowed' }, proposal.items[1]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], estimatedLabel: 'vitamin supplement' }, proposal.items[1]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, provenance: { ...proposal.provenance, medicalAdvice: 'not allowed' } })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, provenance: { ...proposal.provenance, provider: 'apiKey=secret' } })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], calories: range(170, 180, 200) }, proposal.items[1]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], unit: 'unknown' }, proposal.items[1]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [proposal.items[0], proposal.items[0]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, flags: ['mixed_dish'] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, generatedAt: future })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], grams: range(1.23) }, proposal.items[1]] })).toThrow();
  });

  it('rejects invalid confidence/flags, alternatives/notes bounds, inconsistent totals, and implausible macros', () => {
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], confidence: 'certain' }] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], confidence: 'low' }] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], alternatives: ['x', 'x'] }] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], alternatives: ['x', 'diagnosis'] }] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, uncertaintyNotes: Array.from({ length: 9 }, () => 'uncertain') })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, totals: { ...proposal.totals, calories: range(999) } })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], calories: range(1_000), protein: range(1), carbs: range(1), fat: range(1) }, proposal.items[1]] })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, totals: { ...proposal.totals, fiber: range(3) } })).toThrow();
    expect(() => FoodEstimateProposal.parse({ ...proposal, items: [{ ...proposal.items[0], flags: ['needs_confirmation', 'needs_confirmation'] }, proposal.items[1]] })).toThrow();
  });
});

describe('food confirmation contract', () => {
  it('requires versioned lineage and supports confirm/edit/reject actions', () => {
    expect(FoodConfirmationRequest.parse(confirmedMeal).action).toBe('confirm');
    expect(FoodConfirmationRequest.parse({ ...confirmedMeal, action: 'edit_and_confirm', correctionNotes: 'Adjusted yogurt portion from the label.' }).action).toBe('edit_and_confirm');
    expect(FoodConfirmationRequest.parse({ schemaVersion: 1, mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID, action: 'reject', rejectedAt: now, reason: 'Portion was not clear.' }).action).toBe('reject');
    expect(validateFoodConfirmationAgainstProposal(confirmedMeal, proposal).proposalID).toBe(proposal.proposalID);
  });

  it('keeps rejected proposals free of nutrition records and enforces edit, totals, safety, and lineage invariants', () => {
    expect(() => FoodConfirmationRequest.parse({ schemaVersion: 1, mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID, action: 'reject', rejectedAt: now, items: [confirmedItem] })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, correctionNotes: 'Only edits may carry notes.' })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, action: 'edit_and_confirm' })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, totals: { ...confirmedMeal.totals, calories: 151 } })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, items: [confirmedItem, confirmedItem], totals: { grams: 400, calories: 300, protein: 40, carbs: 16, fat: 10, fiber: 0 } })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, confirmedAt: future })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, diagnosis: 'not allowed' })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, items: [{ ...confirmedItem, label: 'allergy treatment' }] })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, requestID: '../credential-path' })).toThrow();
    expect(() => validateFoodConfirmationAgainstProposal({ ...confirmedMeal, mealID: 'other-meal' }, proposal)).toThrow();
    expect(() => validateFoodConfirmationAgainstProposal({ ...confirmedMeal, confirmedAt: earlier }, proposal)).toThrow();
  });

  it('allows an optional meal name and rejects unsafe advice/correction text', () => {
    const withoutName = { ...confirmedMeal, mealName: undefined };
    expect(FoodConfirmationRequest.parse(withoutName).action).toBe('confirm');
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, mealName: 'diagnosis result' })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ ...confirmedMeal, action: 'edit_and_confirm', correctionNotes: 'medical treatment recommendation' })).toThrow();
    expect(() => FoodConfirmationRequest.parse({ schemaVersion: 1, mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID, action: 'reject', rejectedAt: now, reason: 'Bearer token=secret' })).toThrow();
  });
});
