FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --no-audit --no-fund

COPY . .

ENV NODE_ENV=docker
ENV PROJECT_ROOT=/app
ENV NETWORK_DIR=/app/network
ENV PEER_ENDPOINT=peer0.ncc.example.com:7051
ENV COUCHDB_URL=http://couchdb.ncc.example.com:5984
ENV MSP_ID=NCCMSP
ENV PORT=3001

EXPOSE 3001

CMD ["npm", "run", "dev"]
