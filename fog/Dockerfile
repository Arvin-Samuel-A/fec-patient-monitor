FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod .
COPY dashboard ./dashboard
COPY main.go .
RUN go build -o fog-service .

FROM alpine:3.19
WORKDIR /app
COPY --from=builder /app/fog-service .
EXPOSE 8080
CMD ["/app/fog-service"]
