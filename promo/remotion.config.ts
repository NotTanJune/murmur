/**
 * Note: When using the Node.JS APIs, the config file
 * doesn't apply. Instead, pass options directly to the APIs.
 *
 * All configuration options: https://remotion.dev/docs/config
 */

import { Config } from "@remotion/cli/config";

Config.setRspack(true);
Config.setVideoImageFormat("jpeg");
Config.setJpegQuality(92);
// Keep the machine usable while rendering. Run renders under `nice -n 19` as well.
Config.setConcurrency(2);
Config.setOverwriteOutput(true);
Config.setDefaultPremountInSeconds(2);
