# Build context is the repository root so this can pull in packages/schemas,
# the JSON Schema shared across the monorepo (see docs/schemas.md). This is
# the image AWS App Runner runs in production (see infra/apprunner.tf) --
# push it to the ECR repo infra/ecr.tf provisions, then point
# app_service_image_identifier / app_service_image_repository_type at it.

FROM node:20-alpine AS deps
WORKDIR /app
COPY src/app-service/package.json src/app-service/package-lock.json* ./
RUN npm install

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY src/app-service .
COPY packages/schemas ./schemas
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/schemas ./schemas
EXPOSE 8080
CMD ["node", "server.js"]
