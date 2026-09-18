# Runtime image — dependencies are resolved through Artifactory in CI (jf npm install)
# and copied in; no registry auth needed inside the build context.
FROM tomjpd2.jfrog.io/devsecops-docker-virtual/node:20-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY package.json ./
COPY node_modules ./node_modules
COPY src ./src
USER app
EXPOSE 3000
ENV PORT=3000
CMD ["node", "src/server.js"]
