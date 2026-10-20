import type { MetadataRoute } from "next";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: ["/", "/login"],
      disallow: ["/api/", "/account/", "/data-transfer/"],
    },
    sitemap: "https://knowtrace-workflow.vercel.app/sitemap.xml",
  };
}
