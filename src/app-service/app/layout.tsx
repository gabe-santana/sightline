import type { ReactNode } from "react";

export const metadata = {
  title: "Sightline (local)",
  description: "Local app-service for the Sightline video intelligence pipeline",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
