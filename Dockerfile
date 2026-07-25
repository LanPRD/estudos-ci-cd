FROM node:20-alpine AS base

WORKDIR /usr/src/app

# ----------

FROM base AS build

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build
RUN npm prune --omit=dev

# ----------

FROM base AS deploy

COPY --from=build /usr/src/app/node_modules ./node_modules
COPY --from=build /usr/src/app/dist ./dist
COPY package*.json ./

EXPOSE 3000

CMD [ "node", "dist/main" ]
