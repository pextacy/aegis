/**
 * Policy roles, mirroring the ROLE_ constants in PolicyEngine.
 *
 * One address may hold several. The mask is written whole rather than toggled,
 * so what an address may do is visible in one place instead of inferred from a
 * history of grants and revokes — and the dashboard shows it the same way.
 */

export const ROLE_PROPOSER = 1;
export const ROLE_APPROVER = 2;
export const ROLE_GUARDIAN = 4;
export const ROLE_POLICY_ADMIN = 8;
export const ROLE_ALL = 15;

export type RoleDefinition = {
  bit: number;
  key: "proposer" | "approver" | "guardian" | "policyAdmin";
  label: string;
  description: string;
};

export const ROLES: readonly RoleDefinition[] = [
  {
    bit: ROLE_PROPOSER,
    key: "proposer",
    label: "Proposer",
    description: "Proposes payments and dispatches them once approved.",
  },
  {
    bit: ROLE_APPROVER,
    key: "approver",
    label: "Approver",
    description: "Approves payments proposed by someone else. Never their own.",
  },
  {
    bit: ROLE_GUARDIAN,
    key: "guardian",
    label: "Guardian",
    description: "Freezes the treasury alone, with no threshold and no delay.",
  },
  {
    bit: ROLE_POLICY_ADMIN,
    key: "policyAdmin",
    label: "Policy admin",
    description: "Creates treasuries, grants roles, and edits the allowlist.",
  },
];

/** Whether a mask carries a role. */
export function hasRole(mask: number, role: number): boolean {
  return (mask & role) === role;
}

/** The roles in a mask, in the order they are defined. */
export function rolesIn(mask: number): RoleDefinition[] {
  return ROLES.filter((role) => hasRole(mask, role.bit));
}

/** `Proposer, Approver` — or `none` for an address with no authority. */
export function describeRoles(mask: number): string {
  const roles = rolesIn(mask);
  return roles.length === 0 ? "none" : roles.map((role) => role.label).join(", ");
}

/** Builds a mask from a set of role bits. */
export function maskOf(bits: readonly number[]): number {
  return bits.reduce((mask, bit) => mask | bit, 0);
}
