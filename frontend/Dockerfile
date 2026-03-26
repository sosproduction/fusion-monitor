# ── Stage 1: Build React app ─────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json ./
RUN npm install

COPY . .
RUN npm run build

# ── Stage 2: Serve with nginx ─────────────────────────────────────────────────
FROM nginx:1.25-alpine

# Remove default nginx static content
RUN rm -rf /usr/share/nginx/html/*

# Copy built React app
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy custom nginx config (handles SPA routing + Prometheus proxy)
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]