import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { verifyFoundation } from "./check-foundation.mjs";
await verifyFoundation(process.cwd());
const config = await readFile("Sources/DADFoundation/openapi-generator-config.yaml", "utf8");
if (!/^\s*operations:/m.test(config)) throw new Error("Client scope must be explicit");
await mkdir("Sources/DADFoundation", { recursive: true });
for (const [source, target] of [["swift.openapi.json", "openapi.json"], ["DADNullValue.swift", "DADNullValue.swift"], ["DADTokens.swift", "DADTokens.swift"], ["links.json", "links.json"], ["ui-catalog.json", "ui-catalog.json"]]) {
  await copyFile(`contracts/foundation/${source}`, `Sources/DADFoundation/${target}`);
}
// Problem.code is an open set: a newer server may add values, and a generated Swift enum would fail
// the whole response decode on an unknown one. Generate it as a plain string instead.
const spec = JSON.parse(await readFile("Sources/DADFoundation/openapi.json", "utf8"));
const code = spec.components?.schemas?.Problem?.properties?.code;
if (!code?.enum) throw new Error("Problem.code enum not found");
delete code.enum;
// Subscription.status mirrors Stripe's open set (paused, trialing, ... may appear): same treatment. The
// enum is declared on Subscription and again inline where RecurringDetails embeds it, so strip every copy.
let stripped = 0;
const strip = (node) => {
  if (Array.isArray(node)) return node.forEach(strip);
  if (node === null || typeof node !== "object") return;
  const status = node.properties?.status;
  if (status?.enum?.includes("incomplete_expired")) { delete status.enum; stripped += 1; }
  Object.values(node).forEach(strip);
};
strip(spec.components.schemas);
if (stripped < 1) throw new Error("Subscription.status enum not found");
// Event enums are open sets too (DAD-Main documents that clients must tolerate unknown values): the
// kind, the donor's reservation status and the reservation result status decode as plain strings.
for (const [schema, field] of [["EventView", "type"], ["EventView", "reservation_status"], ["ReservationResult", "status"]]) {
  const property = spec.components.schemas[schema]?.properties?.[field];
  if (!property?.enum) throw new Error(`${schema}.${field} enum not found`);
  delete property.enum;
}
const stripEventCopies = (node) => {
  if (Array.isArray(node)) return node.forEach(stripEventCopies);
  if (node === null || typeof node !== "object") return;
  const property = node.properties?.reservation_status;
  if (property?.enum?.includes("WAITLISTED")) delete property.enum;
  Object.values(node).forEach(stripEventCopies);
};
stripEventCopies(spec.components.schemas);
// Engagement enums are open sets as well: a referral conversion's channel (LINK, IRL) may gain a value, and
// a closed Swift enum would fail the whole conversions list on it. Generate it as a plain string.
const conversionKind = spec.components.schemas.Conversion?.properties?.kind;
if (!conversionKind?.enum) throw new Error("Conversion.kind enum not found");
delete conversionKind.enum;
// Partner enums are open sets too: a role, an initiative status, a metric unit or an application status added
// later must not fail the whole portal read. The role is the safety-relevant one (an unknown role is shown
// as the least-privileged VIEWER by `PartnerRole(contract:)`). Fail loudly if the contract moves them.
const partnerBody = (path) => spec.paths?.[path]?.get?.responses?.["200"]?.content?.["application/json"]?.schema;
const openPartnerEnums = [
  ["/donor/partner/overview role", partnerBody("/donor/partner/overview")?.properties?.role],
  ["/donor/partner/initiatives status", partnerBody("/donor/partner/initiatives")?.properties?.initiatives?.items?.properties?.status],
  ["/donor/partner/initiatives metric unit", partnerBody("/donor/partner/initiatives")?.properties?.initiatives?.items?.properties?.metrics?.items?.properties?.unit],
  ["ApplicationStatus.status", spec.components.schemas.ApplicationStatus?.properties?.status],
];
for (const [name, property] of openPartnerEnums) {
  if (!property?.enum) throw new Error(`${name} enum not found`);
  delete property.enum;
}
// The generator cannot name the empty-string reset enum; validate choices in the wire layer.
const zone = spec.paths["/donor/me/profile"].post.requestBody.content["application/json"].schema.properties.timezone_override;
if (!zone?.enum?.includes("")) throw new Error("Time zone reset contract changed");
delete zone.enum;
// The insights layout is validated and drawn by `UIInsights`, which treats every node as untrusted: an unknown
// node type, a newer catalog version or a malformed panel must never fail the dashboard decode. The field is
// generated as free-form JSON instead of the closed UiSpec node schema.
const dashboardBranches = spec.components.schemas.DonorDashboard?.oneOf;
const insightsHolder = dashboardBranches?.find((branch) => branch.properties?.insights);
if (!insightsHolder) throw new Error("DonorDashboard.insights not found");
insightsHolder.properties.insights = { description: "The approved dashboard layout, decoded as free-form JSON; see UIInsights." };
// The bind check resolves a JSON Pointer against the DonorDashboard schema (scripts/ui-catalog.mjs in DAD-Main).
// Flatten every reachable pointer to its kind once here so the app validates binds without shipping the schema.
const catalogSelfField = "insights";
const alternatives = (schema, state = { nullable: false }, depth = 0) => {
  if (depth > 32) throw new Error("Schema nesting too deep");
  if (schema === null || typeof schema !== "object") return [];
  if (schema.$ref) {
    const target = /^#\/components\/schemas\/([^/]+)$/.exec(schema.$ref) && spec.components.schemas[RegExp.$1];
    if (!target) throw new Error(`Unresolvable schema reference: ${schema.$ref}`);
    return alternatives(target, state, depth + 1);
  }
  const branches = schema.oneOf ?? schema.anyOf;
  if (branches) return branches.flatMap((branch) => alternatives(branch, state, depth + 1));
  if (schema.allOf) {
    const parts = schema.allOf.map((part) => alternatives(part, state, depth + 1)).flat();
    const properties = Object.assign({}, ...parts.map((part) => part.properties ?? {}));
    return [{ ...(parts.find((part) => part.type) ?? {}), ...(Object.keys(properties).length ? { properties } : {}) }];
  }
  const types = (Array.isArray(schema.type) ? schema.type : [schema.type]).filter((type) => type && type !== "null");
  return types.map((type) => ({ ...schema, type }));
};
const bindKinds = {};
const walkBinds = (alts, pointer, depth) => {
  if (depth > 12) throw new Error("Dashboard schema nesting too deep for bind table");
  const names = new Set(alts.filter((alt) => alt.type === "object" && alt.properties).flatMap((alt) => Object.keys(alt.properties)));
  for (const name of names) {
    if (depth === 0 && name === catalogSelfField) continue;
    const next = alts.filter((alt) => alt.type === "object" && alt.properties && Object.hasOwn(alt.properties, name))
      .flatMap((alt) => alternatives(alt.properties[name]));
    const at = `${pointer}/${name.replaceAll("~", "~0").replaceAll("/", "~1")}`;
    const kinds = new Set(next.map((alt) => alt.type));
    bindKinds[at] = kinds.size === 1 ? [...kinds][0] : "mixed";
    walkBinds(next, at, depth + 1);
  }
};
walkBinds(alternatives(spec.components.schemas.DonorDashboard), "", 0);
await writeFile("Sources/DADFoundation/ui-binds.json", `${JSON.stringify(bindKinds, null, 1)}\n`);
await writeFile("Sources/DADFoundation/openapi.json", `${JSON.stringify(spec, null, 2)}\n`);
