FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --no-audit --no-fund

COPY . .

ENV CHOKIDAR_USEPOLLING=true
ENV PORT=3000
ENV REACT_APP_API_URL=http://backend:3001

EXPOSE 3000

CMD ["npm", "start"]
