FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

# PUBLIC_ vars must be available at build time for client-side code
ARG PUBLIC_STRAPI_URL=""
ENV PUBLIC_STRAPI_URL=${PUBLIC_STRAPI_URL}

RUN npm run build

ENV HOST=0.0.0.0
ENV PORT=4321

EXPOSE 4321

CMD ["node", "./dist/server/entry.mjs"]
