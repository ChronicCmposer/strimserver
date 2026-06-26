const DEFAULT_BASE = "http://strimserver:4000";

function baseHTTP(): string {
   return process.env.STRIMSERVER_URL?.replace(/\/+$/, "") ?? DEFAULT_BASE;
}

export const Endpoints = {
   control:   () => `${baseHTTP()}/control`,
   status:    () => `${baseHTTP()}/status`,
   subscribe: () => baseHTTP().replace(/^http/, "ws") + "/subscribe",
};
