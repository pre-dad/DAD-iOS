import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { verifyFoundation } from "./check-foundation.mjs";
await verifyFoundation(process.cwd());
await mkdir("Sources/DADFoundation", { recursive: true });
for (const [source, target] of [["swift.openapi.json", "openapi.json"], ["DADNullValue.swift", "DADNullValue.swift"], ["DADTokens.swift", "DADTokens.swift"], ["links.json", "links.json"]]) {
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
let eventEnums = 0;
for (const [schema, field] of [["EventView", "type"], ["EventView", "reservation_status"], ["ReservationResult", "status"]]) {
  const property = spec.components.schemas[schema]?.properties?.[field];
  if (!property?.enum) throw new Error(`${schema}.${field} enum not found`);
  delete property.enum;
  eventEnums += 1;
}
const stripEventCopies = (node) => {
  if (Array.isArray(node)) return node.forEach(stripEventCopies);
  if (node === null || typeof node !== "object") return;
  for (const field of ["reservation_status"]) {
    const property = node.properties?.[field];
    if (property?.enum?.includes("WAITLISTED")) delete property.enum;
  }
  Object.values(node).forEach(stripEventCopies);
};
stripEventCopies(spec.components.schemas);
if (eventEnums < 3) throw new Error("Event enums not found");
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
await writeFile("Sources/DADFoundation/openapi.json", `${JSON.stringify(spec, null, 2)}\n`);
const config = await readFile("Sources/DADFoundation/openapi-generator-config.yaml", "utf8");
if (!config.includes("operations:")) throw new Error("Client scope must be explicit");
