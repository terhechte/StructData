//
//  StructData.swift
//  StructData
//
//  Created by Benedikt Terhechte on 05/07/15.
//  Copyright © 2015 Benedikt Terhechte. All rights reserved.
//

import Foundation
import CoreData

// MARK: Unboxing

/**
Unboxing NSManagedObjects into Value types.

- Unboxing can fail, so the unboxed value is an either type that explains the error via TypeMismatch
- Unboxing cannot utilize the Swift or the NSManagedObject reflection mechanisms as both are too
  dynamic for Swift's typechecker. So we utilize custom operators and curryed object construction
  like in Argo (https://github.com/thoughtbot/Argo) which is also where the gists for the unboxing
  code originates from
- Unboxing defines the 'Unboxing' protocol which a type has to conform to in order to be able
  to be unboxed
*/

// monadic operators
infix operator <^> { associativity left precedence 130 }
infix operator <*> { associativity left precedence 130 }

// pull value/s from nsmanagedobject
infix operator <| { associativity left precedence 150 }
infix operator <|| { associativity left precedence 150 }
infix operator <|? { associativity left precedence 150 }

public func <^> <A, B>(f: A -> B, a: Unboxed<A>) -> Unboxed<B> {
    return a.map(f)
}

public func <*> <A, B>(f: Unboxed<A -> B>, a: Unboxed<A>) -> Unboxed<B> {
    return a.apply(f)
}

public func <| <A where A: Unboxing, A == A.StructureType>(value: NSManagedObject, key: String) -> Unboxed<A> {
    if let s = value.valueForKey(key) {
        return A.unbox(s)
    }
    return Unboxed.TypeMismatch("\(key) \(A.self)")
}

public func <|? <A where A: Unboxing, A == A.StructureType>(value: NSManagedObject, key: String) -> Unboxed<A?> {
    if let s = value.valueForKey(key) {
            return Unboxed<A?>.Success(A.unbox(s).value)
    }
    return Unboxed<A?>.Success(nil)
}

public func <|| <A where A: Unboxing, A == A.StructureType>(value: NSManagedObject, key: String) -> Unboxed<[A]> {
    if let s = value.valueForKey(key) {
        return Array.unbox(s)
    }
    return Unboxed.TypeMismatch("\(key) \(A.self)")
}

/**
Each Unboxing operation returns this either type which allows unboxing to fail
if the NSManagedObject does not offer the correct values / datatypes for the
Value type that is to be constructed.

- parameter T: is the value type that we're trying to construct.
*/
public enum Unboxed<T> {
    case Success(T)
    case TypeMismatch(String)
    
    public var value: T? {
        switch self {
        case let .Success(value): return value
        default: return .None
        }
    }
}

/**
Support for Monadic operations on the Unboxed type
*/
public extension Unboxed {
    func map<U>(f: T -> U) -> Unboxed<U> {
        switch self {
        case let .Success(value): return .Success(f(value))
        case let .TypeMismatch(string): return .TypeMismatch(string)
        }
    }
    
    func apply<U>(f: Unboxed<T -> U>) -> Unboxed<U> {
        switch f {
        case let .Success(value): return value <^> self
        case let .TypeMismatch(string): return .TypeMismatch(string)
        }
    }
}

/**
The *Unboxing* protocol
The *unbox* function recieves a Core Data object and returns an unboxed value type. This value type
is defined by the StructureType typealias
*/
public protocol Unboxing {
    typealias StructureType = Self
    /**
    Unbox a data from an NSManagedObject instance (or the instance itself) into a value type
    - parameter value: The data to be unboxed into a value type
    */
    static func unbox(value: AnyObject) -> Unboxed<StructureType>
}

// MARK: -
// MARK: Boxing

/**
Boxing value types into NSManagedObject instances

- Boxing can fail if the value type in question is not supported (i.e. enum) or doesn't conform to the Boxing
  protocol
- Boxing requires the name of the entity that the boxed NSManagedObject maps to. It would be possible
  to just use the value type's name (i.e. struct Employee) but I decided against it to give the user
  more control over this
*/

public protocol Boxing {
    
    /** The name of the Core Data entity that the boxed value type should become */
    static var EntityName: String {get}
    
    /** Box Self into the given managed object with key *withKey*
    - parameter object: The NSManagedObject that the value type self should be boxed into
    - parameter withKey: The name of the property in the NSManagedObject that it should be written to
    */
    func box(object: NSManagedObject, withKey: String) throws
}

/**
Boxing will also be used for minor value types like Int16 or Int32. Those don't require a
EntityName. Thus, by default the EntityName is the empty string

FIXME: Consider just making EntityName optional
*/
public extension Boxing {
    static var EntityName: String { return "" }
}

public protocol BoxingStruct : Boxing {
    /**
    Convert the current UnboxingStruct instance to a NSManagedObject
    throws 'NSManagedStructError' if the process fails.
    
    The implementation for this is included via an extension (see below)
    it uses reflection to automatically convert this
    
    - parameter context: An Optional NSManagedObjectContext. If it is not provided, the objects
    are only temporary.
    */
    func toObject(context: NSManagedObjectContext?) throws -> NSManagedObject
}

extension BoxingStruct {
    public func box(object: NSManagedObject, withKey: String) throws {
        try object.setValue(self.toObject(object.managedObjectContext), forKey: withKey)
    }
}

/**
   Add support for persistence, i.e. entities that know they were fetched from a context
   and can appropriately update themselves in the context, or be deleted, etc.
   Still a basic implementation.

   Caveats:
   - If type T: BoxingPersistentStruct has a property Tx: BoxingStruct, then saving/boxing
     T will create new instances of Tx. So, as a requirement that is with the current swift compiler
     impossible to define in types, any property on BoxingPersistentStruct also has to be of
     type BoxingPersistentStruct
   - Things like deletion don't work yet, there's also no way to enforce saving a persistent
     object right now except for calling mutatingToObject again
*/

public protocol BoxingPersistentStruct : BoxingStruct {
    /** If this value type is based on an existing object, this is the object id, so we can
        locate it and update it in the  managedobjectstore instead of re-inserting it*/
    var objectID: NSManagedObjectID? {get set}
    
    /** Persistent structs update their objectID when saving. This means that the toObject
        call needs to be mutating. Calling simply toObject will also work, but will fail
        to update the objectID, thus causing multiple insertions (into the context) of the 
        same object during update */
    mutating func mutatingToObject(context: NSManagedObjectContext?) throws -> NSManagedObject
}

public protocol UnboxingStruct : Unboxing {
    /** 
    Call on any UnboxingStruct supporting object to create a self instance from a
    NSManagedObject. 
    
    The fromObject implementation can be implemented with custom operators
    to quickly map the object properties onto the required types (see examples)
    
    - parameter object: The NSManagedObject that should be converted to an instance of self
    */
    static func fromObject(object: NSManagedObject) -> Unboxed<Self>
}

extension UnboxingStruct {
    public static func unbox<A: UnboxingStruct where A==A.StructureType>(value: AnyObject) -> Unboxed<A> {
        if let v = value as? NSManagedObject {
            return A.fromObject(v)
        }
        return Unboxed.TypeMismatch("\(value) is not NSManagedObject")
    }
}

// MARK: -
// MARK: NSManagedStruct

/**
Type aliases for boxing/unboxing support, and the same for persistence
*/
typealias NSManagedStruct = protocol<BoxingStruct, UnboxingStruct>

typealias NSManagedPersistentStruct = protocol<BoxingPersistentStruct, UnboxingStruct>

// MARK: Querying

/**
BoxingStruct extensions for querying CoreData with predicates

- There's certainly a lot of low hanging fruit here to be implemented, such as a better way of querying, 
  i.e. a more type safe NSPredicate
- Or a more type safe way of describing order.

For a first release, this should do though.
*/
extension BoxingStruct {
    
    public static func query<T: UnboxingStruct>(context: NSManagedObjectContext, predicate: NSPredicate?, sortDescriptors: Array<NSSortDescriptor>) -> Array<T> {
        let fetchRequest = NSFetchRequest(entityName: self.EntityName)
        
        fetchRequest.sortDescriptors = sortDescriptors
        
        if let p = predicate {
            fetchRequest.predicate = p
        }
        
        do {
            let fetchResults = try context.executeFetchRequest(fetchRequest)
            var results: [T] = []
            for result in fetchResults {
                if let result = result as? NSManagedObject {
                    let value = T.fromObject(result)
                    if let unboxedValue = value.value {
                        results.append(unboxedValue)
                    }
                }
            }
            return results
        } catch _ {
            return []
        }
    }
    
    public static func query<T: UnboxingStruct>(context: NSManagedObjectContext, predicate: NSPredicate?) -> Array<T> {
        return self.query(context, predicate: predicate, sortDescriptors: Array<NSSortDescriptor>())
    }
}

// MARK: -
// MARK: Type Extensions

// Extending existing value types to support Boxing and Unboxing
// For all types that core data supports

/**
NSManagedObject already contains implementations for unbox and box
*/
extension NSManagedObject: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<NSManagedObject> {
        return Unboxed.Success(value as! NSManagedObject)
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}
extension NSManagedObjectID: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<NSManagedObjectID> {
        return Unboxed.Success(value as! NSManagedObjectID)
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}

/**
Arrays cannot implement the Unboxing protocol because they do not contain a 
one to one mapping of the type T1 input to the type T2 output. Instead, they map
from T1 input to [T2] output. In order to get the type checker to understand this,
we can informally support the unboxing protocol by explaining the types in terms of
type constraints. 

- Currently, there's no support for NSSet
*/
extension Array where T: Unboxing, T == T.StructureType {
    public static func unbox(value: AnyObject) -> Unboxed<[T]> {
        switch value {
        case let orderedSet as NSOrderedSet:
            var container: [T] = []
            // Each entry has to be unboxed seperately and then the unboxed
            // value will be in an 'Unboxed' array. Also, unboxing may always fail,
            // which is why we have to check it via an if let
            for boxedEntry in orderedSet {
                if let value = T.unbox(boxedEntry).value {
                    container.append(value)
                }
            }
            return Unboxed.Success(container)
        default: return Unboxed.TypeMismatch("Array")
        }
    }
}

extension Int: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Int> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(v.integerValue)
        default: return Unboxed.TypeMismatch("Int")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(integer: self), forKey: withKey)
    }
}

extension Int16: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Int16> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(Int16(v.intValue))
        default: return Unboxed.TypeMismatch("Int16")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(short: self), forKey: withKey)
    }
}

extension Int32: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Int32> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(Int32(v.intValue))
        default: return Unboxed.TypeMismatch("Int32")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(int: self), forKey: withKey)
    }
}

extension Int64: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Int64> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(Int64(v.longLongValue))
        default: return Unboxed.TypeMismatch("Int64")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(longLong: self), forKey: withKey)
    }
}

extension Double: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Double> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(v.doubleValue)
        default: return Unboxed.TypeMismatch("Double")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(double: self), forKey: withKey)
    }
}

extension Float: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Float> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(v.floatValue)
        default: return Unboxed.TypeMismatch("Float")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(float: self), forKey: withKey)
    }
}

extension Bool: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<Bool> {
        switch value {
        case let v as NSNumber: return Unboxed.Success(v.boolValue)
        default: return Unboxed.TypeMismatch("Boolean")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(NSNumber(bool: self), forKey: withKey)
    }
}

extension String: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<String> {
        switch value {
        case let v as String: return Unboxed.Success(v)
        default: return Unboxed.TypeMismatch("String")
        }
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}

extension NSData: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<NSData> {
        if let s = value as? NSData {
            return Unboxed.Success(s)
        }
        return Unboxed.TypeMismatch("NSData")
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}

extension NSDate: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<NSDate> {
        if let s = value as? NSDate {
            return Unboxed.Success(s)
        }
        return Unboxed.TypeMismatch("NSDate")
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}

extension NSDecimalNumber: Unboxing, Boxing {
    public static func unbox(value: AnyObject) -> Unboxed<NSDecimalNumber> {
        if let s = value as? NSDecimalNumber {
            return Unboxed.Success(s)
        }
        return Unboxed.TypeMismatch("NSDecimalNumber")
    }
    public func box(object: NSManagedObject, withKey: String) throws {
        object.setValue(self, forKey: withKey)
    }
}

// MARK: -
// MARK: Reflection Support

/**
This error will be thrown if boxing fails because the core data model
does not know or support the requested property
*/
public enum NSManagedStructError : ErrorType {
    case StructConversionError(message: String)
    case StructValueError(message: String)
    case StructUpdateError(message: String)
}

/**
Extend *Boxing* with code that utilizes reflection to convert a value type into an
NSManagedObject
*/

private func virginObjectForEntity(entity: String, context: NSManagedObjectContext?) -> NSManagedObject {
    let desc = NSEntityDescription.entityForName(entity, inManagedObjectContext:(context ?? nil)!)
    guard let _ = desc else {
        fatalError("entity \(entity) not found in Core Data Model")
    }
    
    return NSManagedObject(entity: desc!, insertIntoManagedObjectContext: context)
}

private extension BoxingStruct {
    private func managedObject(context: NSManagedObjectContext?) throws -> NSManagedObject {
        return virginObjectForEntity(self.dynamicType.EntityName, context: context)
    }
}

private extension BoxingPersistentStruct {
    private func managedObject(context: NSManagedObjectContext?) throws -> NSManagedObject {
        if let objectID = self.objectID,
           ctx = context {
            do {
                return try ctx.existingObjectWithID(objectID)
            } catch let error {
                // In this case, we don't want to just insert a new object,
                // instead we should tell the user about this issue.
                throw NSManagedStructError.StructUpdateError(message: "Could not fetch object \(self) for id \(objectID): \(error)")
            }
        } else {
            return virginObjectForEntity(self.dynamicType.EntityName, context: context)
        }
    }
}

public extension BoxingStruct {
    func toObject(context: NSManagedObjectContext?) throws -> NSManagedObject {
        // Only create an entity, if it doesn't exist yet, otherwise update it
        // We can detect existing entities via the objectID property that is part of UnboxingStruct
        let result = try self.managedObject(context)
        
        return try internalToObject(context, result: result, entity: self)
    }
}

public extension BoxingPersistentStruct {
    mutating func mutatingToObject(context: NSManagedObjectContext?) throws -> NSManagedObject {
        
        // Only create an entity, if it doesn't exist yet, otherwise update it
        // We can detect existing entities via the objectID property that is part of UnboxingStruct
        var result = try self.managedObject(context)
        
        result = try internalToObject(context, result: result, entity: self)
        if let ctx = context {
            try ctx.save()
            // if it succeeded, update the objectID
            self.objectID = result.objectID
        }
        return result
    }
}

private func internalToObject<T: BoxingStruct>(context: NSManagedObjectContext?, result: NSManagedObject, entity: T) throws -> NSManagedObject {
    
    let mirror = Mirror(reflecting: entity)
    
    if let style = mirror.displayStyle where style == .Struct {
        
        
        for (labelMaybe, valueMaybe) in mirror.children {
            
            guard let label = labelMaybe else {
                continue
            }
            
            // We don't want to assign the objectID here
            if ["objectID"].contains(label) {
                continue
            }
            
            // FIXME: This still looks awful. Need to spend more time cleaning this up
            if let value = valueMaybe as? Boxing {
                try value.box(result, withKey: label)
            } else {
                let valueMirror:MirrorType = reflect(valueMaybe)
                if valueMirror.count == 0 {
                    result.setValue(nil, forKey: label)
                } else {
                    // Since MirrorType has no typealias for it's children, we have to 
                    // unpack the first one in order to identify them
                    switch (valueMirror.count, valueMirror.disposition, valueMirror[0]) {
                    case (_, .Optional, (_, let some)) where some.value is AnyObject:
                        result.setValue(some.value as? AnyObject, forKey: label)
                    case (_, .IndexContainer, (_, let some)) where some.value is BoxingStruct:
                        // Since valueMirror isn't an array type, we can't map over it or even properly extend it
                        // Matching valueMaybe against [_Structured], on the other hand, doesn't work either
                        var objects: [NSManagedObject] = []
                        for c in 0..<valueMirror.count {
                            if let value = valueMirror[c].1.value as? BoxingStruct {
                                objects.append(try value.toObject(context))
                            }
                        }
                        
                        if objects.count > 0 {
                            let mutableValue = result.mutableOrderedSetValueForKey(label)
                            mutableValue.addObjectsFromArray(objects)
                        }
                        
                    default:
                        // If we end up here, we were unable to decode it
                        throw NSManagedStructError.StructValueError(message: "Could not decode value for field '\(label)' obj \(valueMaybe)")
                    }
                }
            }
        }
        
        return result
    }
    throw NSManagedStructError.StructConversionError(message: "Object is not a struct: \(entity)")
}

