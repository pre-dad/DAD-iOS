// Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
import { execFileSync } from "node:child_process";

const { devices } = JSON.parse(
  execFileSync("xcrun", ["simctl", "list", "devices", "available", "--json"], { encoding: "utf8" }),
);
const version = (runtime) => (/iOS-(\d+)-(\d+)/.exec(runtime) ?? []).slice(1).map(Number);
const compare = (a, b) => (a[0] ?? 0) - (b[0] ?? 0) || (a[1] ?? 0) - (b[1] ?? 0);
const found = Object.entries(devices)
  .filter(([runtime]) => runtime.includes("iOS"))
  .sort(([a], [b]) => compare(version(b), version(a)))
  .flatMap(([, list]) => list)
  .find((device) => device.name.startsWith("iPhone") && device.isAvailable);
if (!found) {
  console.error("No available iPhone simulator");
  process.exit(1);
}
process.stdout.write(found.udid);
