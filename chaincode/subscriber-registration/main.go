package main

import (
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&SubscriberRegistrationContract{})
	if err != nil {
		panic("Error creating SubscriberRegistrationContract: " + err.Error())
	}
	if err := cc.Start(); err != nil {
		panic("Error starting SubscriberRegistrationContract: " + err.Error())
	}
}
