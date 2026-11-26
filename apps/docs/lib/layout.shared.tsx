import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";

export const repoUrl = "https://github.com/lacrew/lacrew";

export function baseOptions(): BaseLayoutProps {
  return {
    nav: { title: "LaCrew docs" },
    githubUrl: repoUrl,
  };
}
